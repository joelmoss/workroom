package config

import "reflect"

// ClaimProvisioned moves into c every remote entry in shared that provisioner made: each
// workroom whose host it made and each project base it made, under its project, which c gains
// (with its vcs) when it has none. A Dev build of the desktop app keeps its own config, and this
// takes what it made out of the config Release and Nightly share. Returns how many entries left
// shared, and touches neither file when there are none.
//
// c is written before shared is changed, so a crash in between leaves an entry in both, which
// the next call takes out of shared, and never in neither: an entry is the only record of a
// machine that is still running.
func (c *Config) ClaimProvisioned(shared *Config, provisioner string) (int, error) {
	if provisioner == "" || shared.path == c.path {
		return 0, nil
	}
	var from map[string]any
	if err := shared.withLock(func() (err error) {
		from, err = shared.Read()
		return err
	}); err != nil {
		return 0, err
	}
	claims := provisioned(from, provisioner)
	if len(claims) == 0 {
		return 0, nil
	}
	var mine map[string]any
	if err := c.withLock(func() (err error) {
		if mine, err = c.Read(); err != nil {
			return err
		}
		for _, claim := range claims {
			claim.addTo(mine)
		}
		// One workrooms directory for both, as before: a name is never given to two worktrees.
		if dir, ok := from["workrooms_dir"]; ok {
			if _, set := mine["workrooms_dir"]; !set {
				mine["workrooms_dir"] = dir
			}
		}
		return c.Write(mine)
	}); err != nil {
		return 0, err
	}
	moved := 0
	err := shared.withLock(func() error {
		data, err := shared.Read()
		if err != nil {
			return err
		}
		if moved = removeClaimed(data, mine, provisioner); moved == 0 {
			return nil
		}
		return shared.Write(data)
	})
	return moved, err
}

// claim is what one project holds that a provisioner made.
type claim struct {
	project   string
	vcs       any
	workrooms map[string]any
	bases     []any
}

func madeBy(host any, provisioner string) bool {
	h, ok := host.(map[string]any)
	return ok && h["provisioner"] == provisioner
}

// bases returns a project's base descriptors, in either shape a project's host takes: a list
// under "bases", or (as written before a project could have more than one) the host itself.
func bases(project map[string]any) []any {
	host, ok := project["host"].(map[string]any)
	if !ok {
		return nil
	}
	if list, ok := host["bases"].([]any); ok {
		return list
	}
	return []any{host}
}

func projects(data map[string]any) map[string]map[string]any {
	out := map[string]map[string]any{}
	for key, value := range data {
		if project, ok := value.(map[string]any); ok && !isReserved(key) {
			out[key] = project
		}
	}
	return out
}

func provisioned(data map[string]any, provisioner string) []claim {
	var claims []claim
	for key, project := range projects(data) {
		found := claim{project: key, vcs: project["vcs"], workrooms: map[string]any{}}
		workrooms, _ := project["workrooms"].(map[string]any)
		for name, entry := range workrooms {
			if e, ok := entry.(map[string]any); ok && madeBy(e["host"], provisioner) {
				found.workrooms[name] = entry
			}
		}
		for _, base := range bases(project) {
			if madeBy(base, provisioner) {
				found.bases = append(found.bases, base)
			}
		}
		if len(found.workrooms) > 0 || len(found.bases) > 0 {
			claims = append(claims, found)
		}
	}
	return claims
}

// sameBase compares bases by their host ID, or whole when they have none.
func sameBase(a, b any) bool {
	am, _ := a.(map[string]any)
	bm, _ := b.(map[string]any)
	if am["id"] != nil || bm["id"] != nil {
		return am["id"] == bm["id"]
	}
	return reflect.DeepEqual(a, b)
}

func hasBase(list []any, base any) bool {
	for _, b := range list {
		if sameBase(b, base) {
			return true
		}
	}
	return false
}

// addTo puts the claim into data, keeping whatever data already holds.
func (cl claim) addTo(data map[string]any) {
	project, ok := data[cl.project].(map[string]any)
	if !ok {
		project = map[string]any{"vcs": cl.vcs}
		data[cl.project] = project
	}
	workrooms, ok := project["workrooms"].(map[string]any)
	if !ok {
		workrooms = map[string]any{}
		project["workrooms"] = workrooms
	}
	for name, entry := range cl.workrooms {
		if _, exists := workrooms[name]; !exists {
			workrooms[name] = entry
		}
	}
	list := bases(project)
	before := len(list)
	for _, base := range cl.bases {
		if !hasBase(list, base) {
			list = append(list, base)
		}
	}
	if len(list) > before {
		project["host"] = map[string]any{"bases": list}
	}
}

// removeClaimed takes out of data each entry provisioner made that mine now holds, and returns
// how many it took. A project left with no base loses its host, so nothing reads it as having one.
func removeClaimed(data, mine map[string]any, provisioner string) int {
	removed := 0
	for key, project := range projects(data) {
		claimed, _ := mine[key].(map[string]any)
		held, _ := claimed["workrooms"].(map[string]any)
		workrooms, _ := project["workrooms"].(map[string]any)
		for name, entry := range workrooms {
			e, ok := entry.(map[string]any)
			if _, has := held[name]; ok && has && madeBy(e["host"], provisioner) {
				delete(workrooms, name)
				removed++
			}
		}
		heldBases := bases(claimed)
		var kept []any
		for _, base := range bases(project) {
			if madeBy(base, provisioner) && hasBase(heldBases, base) {
				removed++
				continue
			}
			kept = append(kept, base)
		}
		if len(kept) == len(bases(project)) {
			continue
		}
		if len(kept) == 0 {
			delete(project, "host")
		} else {
			project["host"] = map[string]any{"bases": kept}
		}
	}
	return removed
}

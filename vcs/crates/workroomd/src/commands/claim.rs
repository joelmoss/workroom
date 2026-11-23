//! `workroom claim-provisioned --from <config> --provisioner <bundle id>`: moves what one desktop
//! build made out of the config other builds share and into this one (`$WORKROOM_CONFIG`). A Dev
//! build keeps its own config, so its remote workrooms and bases must not stay where Release and
//! Nightly read them: a base another build made blocks their creates. Go's `ClaimProvisioned`,
//! step for step.
//!
//! This config is written before the shared one is changed, so a crash in between leaves an entry
//! in both, which the next claim takes out of the shared one, and never in neither: an entry is the
//! only record of a machine that is still running. Neither file is touched when there is nothing
//! to claim. `--pretend` touches neither, and says how many entries a real run would move (#798;
//! Go's moved them anyway).

use serde::Serialize;

use super::config::{Config, Json, is_reserved};
use super::envelope;
use super::kind::CliError;
use super::{Args, Context, Outcome};

type Object = std::collections::BTreeMap<String, Json>;

#[derive(Serialize)]
struct Payload {
    moved: usize,
}

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    match claim(context, args) {
        Ok(_) if !context.json => Outcome::Printed(String::new()),
        Ok(moved) => Outcome::Success(envelope::success("claim-provisioned", &Payload { moved })),
        Err(error) => Outcome::Failed(error),
    }
}

fn claim(context: &Context, args: &Args) -> Result<usize, CliError> {
    let mine = Config::new(context)?;
    let shared = Config::named(args.value_or_default("from"), context)?;
    let provisioner = args.value_or_default("provisioner");
    if provisioner.is_empty() || shared.path() == mine.path() {
        return Ok(0);
    }
    // A plain read under `--pretend`, since taking the lock makes its file.
    let from = if context.pretend {
        shared.read()?
    } else {
        shared.read_locked()?
    };
    let claims = provisioned(&from, provisioner);
    if claims.is_empty() {
        return Ok(0);
    }
    if context.pretend {
        // The claim made on copies of both, so the count is the real run's and nothing is written.
        let mut held = mine.read()?;
        take(&mut held, &claims, &from);
        return Ok(remove_claimed(&mut from.clone(), &held, provisioner));
    }
    let mut held = Json::Null;
    mine.update(|data| {
        take(data, &claims, &from);
        held = data.clone();
        Ok(true)
    })?;
    let mut moved = 0;
    shared.update(|data| {
        moved = remove_claimed(data, &held, provisioner);
        Ok(moved > 0)
    })?;
    Ok(moved)
}

/// Puts `claims` into `data`, this config, with the workrooms directory of `from`, the shared one,
/// when `data` names none.
fn take(data: &mut Json, claims: &[Claim], from: &Json) {
    // Go's map: a `null` config reads as an empty one here.
    if !matches!(data, Json::Object(_)) {
        *data = Json::Object(Object::new());
    }
    let top = data.as_object_mut().expect("just made an object");
    for claim in claims {
        claim.add_to(top);
    }
    // One workrooms directory for both, as before: a name is never given to two worktrees.
    if let Some(dir) = from.as_object().and_then(|from| from.get("workrooms_dir")) {
        top.entry("workrooms_dir".to_string())
            .or_insert_with(|| dir.clone());
    }
}

/// What one project holds that the provisioner made.
struct Claim {
    project: String,
    vcs: Option<Json>,
    workrooms: Object,
    bases: Vec<Json>,
}

impl Claim {
    /// Puts the claim into `data`, keeping whatever `data` already holds.
    fn add_to(&self, data: &mut Object) {
        let project = data.entry(self.project.clone()).or_insert(Json::Null);
        if !matches!(project, Json::Object(_)) {
            let mut entry = Object::new();
            // Go's `{"vcs": cl.vcs}`: null when the shared entry had none.
            entry.insert("vcs".to_string(), self.vcs.clone().unwrap_or(Json::Null));
            *project = Json::Object(entry);
        }
        let project = project.as_object_mut().expect("just made an object");
        if project.get("workrooms").and_then(Json::as_object).is_none() {
            project.insert("workrooms".to_string(), Json::Object(Object::new()));
        }
        let workrooms = project
            .get_mut("workrooms")
            .and_then(Json::as_object_mut)
            .expect("just made an object");
        for (name, entry) in &self.workrooms {
            workrooms
                .entry(name.clone())
                .or_insert_with(|| entry.clone());
        }
        let mut list = bases(project);
        let before = list.len();
        for base in &self.bases {
            if !has_base(&list, base) {
                list.push(base.clone());
            }
        }
        if list.len() > before {
            project.insert("host".to_string(), host_with(list));
        }
    }
}

/// `{"bases": list}`, the shape a project's host takes once it has more than one.
fn host_with(list: Vec<Json>) -> Json {
    let mut host = Object::new();
    host.insert("bases".to_string(), Json::Array(list));
    Json::Object(host)
}

/// Whether `host` is a descriptor `provisioner` made.
fn made_by(host: Option<&Json>, provisioner: &str) -> bool {
    host.and_then(Json::as_object)
        .and_then(|host| host.get("provisioner"))
        .and_then(Json::as_str)
        == Some(provisioner)
}

/// A project's base descriptors, in either shape its host takes: a list under `bases`, or (as
/// written before a project could have more than one) the host itself.
fn bases(project: &Object) -> Vec<Json> {
    let Some(host) = project
        .get("host")
        .filter(|host| host.as_object().is_some())
    else {
        return Vec::new();
    };
    match host.as_object().and_then(|host| host.get("bases")) {
        Some(Json::Array(list)) => list.clone(),
        _ => vec![host.clone()],
    }
}

/// The projects in `data`: its object values but the scalar settings' keys.
fn projects(data: &Json) -> impl Iterator<Item = (&String, &Object)> {
    data.as_object()
        .into_iter()
        .flatten()
        .filter(|(key, _)| !is_reserved(key))
        .filter_map(|(key, value)| Some((key, value.as_object()?)))
}

fn provisioned(data: &Json, provisioner: &str) -> Vec<Claim> {
    let mut claims = Vec::new();
    for (key, project) in projects(data) {
        let mut found = Claim {
            project: key.clone(),
            vcs: project.get("vcs").cloned(),
            workrooms: Object::new(),
            bases: Vec::new(),
        };
        if let Some(workrooms) = project.get("workrooms").and_then(Json::as_object) {
            for (name, entry) in workrooms {
                let host = entry.as_object().and_then(|entry| entry.get("host"));
                if made_by(host, provisioner) {
                    found.workrooms.insert(name.clone(), entry.clone());
                }
            }
        }
        for base in bases(project) {
            if made_by(Some(&base), provisioner) {
                found.bases.push(base);
            }
        }
        if !found.workrooms.is_empty() || !found.bases.is_empty() {
            claims.push(found);
        }
    }
    claims
}

/// Compares bases by their host ID, or whole when they have none. Numbers compare by their text,
/// as Go's `json.Number` does.
fn same_base(a: &Json, b: &Json) -> bool {
    let id = |base: &Json| {
        base.as_object()
            .and_then(|base| base.get("id"))
            .filter(|id| **id != Json::Null)
            .cloned()
    };
    let (a_id, b_id) = (id(a), id(b));
    if a_id.is_none() && b_id.is_none() {
        return a == b;
    }
    a_id == b_id
}

fn has_base(list: &[Json], base: &Json) -> bool {
    list.iter().any(|known| same_base(known, base))
}

/// Takes out of `data` each entry `provisioner` made that `mine` now holds, and returns how many
/// it took. A project left with no base loses its host, so nothing reads it as having one.
fn remove_claimed(data: &mut Json, mine: &Json, provisioner: &str) -> usize {
    let Json::Object(top) = data else {
        return 0;
    };
    let mut removed = 0;
    for (key, value) in top.iter_mut() {
        if is_reserved(key) {
            continue;
        }
        let Json::Object(project) = value else {
            continue;
        };
        let claimed = mine
            .as_object()
            .and_then(|mine| mine.get(key))
            .and_then(Json::as_object);
        let held = claimed
            .and_then(|claimed| claimed.get("workrooms"))
            .and_then(Json::as_object);
        if let Some(Json::Object(workrooms)) = project.get_mut("workrooms") {
            workrooms.retain(|name, entry| {
                let host = entry.as_object().and_then(|entry| entry.get("host"));
                let take = entry.as_object().is_some()
                    && held.is_some_and(|held| held.contains_key(name))
                    && made_by(host, provisioner);
                removed += usize::from(take);
                !take
            });
        }
        let held_bases = claimed.map(bases).unwrap_or_default();
        let all = bases(project);
        let kept: Vec<Json> = all
            .iter()
            .filter(|base| {
                let take = made_by(Some(base), provisioner) && has_base(&held_bases, base);
                removed += usize::from(take);
                !take
            })
            .cloned()
            .collect();
        if kept.len() == all.len() {
            continue;
        }
        if kept.is_empty() {
            project.remove("host");
        } else {
            project.insert("host".to_string(), host_with(kept));
        }
    }
    removed
}

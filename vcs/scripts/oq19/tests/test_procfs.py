"""Parser tests against REAL output captured inside the measurement image (tests/fixtures/).

Run by file name: `python3 vcs/scripts/oq19/tests/test_procfs.py` (never `unittest discover`, which exits 0
when the suite disappears).
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

import procfs  # noqa: E402


def fixture(name):
    with open(os.path.join(HERE, "fixtures", name)) as f:
        return f.read()


class Stat(unittest.TestCase):
    def test_a_real_process(self):
        s = procfs.parse_stat(fixture("stat_sleep.txt"))
        self.assertEqual(s["comm"], "sleep")
        self.assertEqual(s["state"], "S")
        self.assertEqual(s["ppid"], 1)
        self.assertEqual(procfs.cpu_ticks(s), s["utime"] + s["stime"])

    def test_a_self_renamed_process_with_spaces_and_a_paren_in_its_comm(self):
        """Captured from a real process that set its own name to `evil) S 1 (x`. Splitting on whitespace, or
        on the first ')', reads `S` as the state and `1` as the ppid: the fields below are the true ones."""
        text = fixture("stat_weird_comm.txt")
        s = procfs.parse_stat(text)
        self.assertEqual(s["comm"], "evil) S 1 (x")
        self.assertEqual(s["state"], "R")  # not the fake "S" inside the name
        self.assertEqual(s["ppid"], 1)
        self.assertGreater(s["starttime"], 0)
        naive = text.split()
        self.assertNotEqual(naive[2], s["state"])  # proves a whitespace split would have been wrong

    def test_truncated_or_empty_input_is_none_not_a_guess(self):
        self.assertIsNone(procfs.parse_stat(""))
        self.assertIsNone(procfs.parse_stat("12 (sleep) S 1 1"))  # truncated mid-line
        self.assertIsNone(procfs.parse_stat("garbage"))
        self.assertIsNone(procfs.parse_stat("x (a) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 1"))  # pid not a number


class CgroupAndBox(unittest.TestCase):
    def test_cgroup_cpu_stat(self):
        c = procfs.parse_cgroup_cpu_stat(fixture("cgroup_cpu_stat.txt"))
        self.assertGreater(c["usage_usec"], 0)
        self.assertEqual(c["usage_usec"], c["user_usec"] + c["system_usec"])

    def test_proc_stat_fallback_returns_busy_and_total_ticks(self):
        busy, total = procfs.parse_proc_stat_cpu(fixture("proc_stat_cpu.txt"))
        self.assertGreater(total, busy)
        self.assertGreater(busy, 0)
        self.assertIsNone(procfs.parse_proc_stat_cpu("intr 12 34"))
        self.assertIsNone(procfs.parse_proc_stat_cpu("cpu 1 2 3"))

    def test_loadavg(self):
        self.assertIsInstance(procfs.parse_loadavg(fixture("loadavg.txt")), float)
        self.assertIsNone(procfs.parse_loadavg(""))

    def test_cgroup_procs(self):
        pids = procfs.parse_cgroup_procs(fixture("cgroup_procs.txt"))
        self.assertIn(1, pids)
        self.assertEqual(procfs.parse_cgroup_procs("1\n17\nx\n"), [1, 17])

    def test_net_dev_and_the_provider_visible_total_excludes_loopback(self):
        n = procfs.parse_net_dev(fixture("net_dev.txt"))
        self.assertIn("eth0", n)
        self.assertIn("lo", n)
        rx, tx = procfs.net_bytes(n)
        self.assertEqual((rx, tx), n["eth0"])  # the only non-lo interface with traffic in the fixture
        lo = {"lo": (10**9, 10**9), "eth0": (5, 7)}
        self.assertEqual(procfs.net_bytes(lo), (5, 7))  # loopback chatter must not look like network activity

    def test_internal_bridges_and_their_virtual_ports_are_not_counted(self):
        import tempfile
        with tempfile.TemporaryDirectory() as sys_net:
            layout = {"eth0": (["device"], None), "docker0": (["bridge"], None),
                      "veth1": (["brport"], "docker0"), "br0": (["bridge"], None),
                      "lxc-eth0": (["brport"], "br0"), "orphan": (["brport"], None)}
            for name, (entries, master) in layout.items():
                os.makedirs(os.path.join(sys_net, name))
                for entry in entries:
                    os.makedirs(os.path.join(sys_net, name, entry))
                if master:
                    os.symlink("../" + master, os.path.join(sys_net, name, "master"))
            counted = lambda name: procfs.crosses_the_box(name, {"br0"}, sys_net)
            net = {"eth0": (1, 2), "docker0": (10, 20), "veth1": (100, 200), "br0": (1000, 2000),
                   "lxc-eth0": (10000, 20000), "orphan": (100000, 200000), "unknown0": (1000000, 2000000)}
            # docker0 and its veth are internal; the uplink bridge br0, the LXC eth0 on it, a port whose
            # bridge cannot be read, and an interface sysfs does not know all count.
            self.assertEqual(procfs.net_bytes(net, counted=counted), (1111001, 2222002))
            no_default = lambda name: procfs.crosses_the_box(name, set(), sys_net)
            self.assertEqual(procfs.net_bytes(net, counted=no_default), (1111111, 2222222))

    def test_default_route_interfaces_reads_both_families(self):
        route = "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n" \
                "br0\t00000000\t0101A8C0\t0003\t0\t0\t0\t00000000\n" \
                "docker0\t0000C80A\t00000000\t0001\t0\t0\t0\t00FFFFFF\n"
        ipv6 = ("0" * 32 + " 00 " + "0" * 32 + " 00 " + "0" * 32 + " 00000400 00000001 00000000 00000003 eth1\n"
                + "0" * 32 + " 00 " + "0" * 32 + " 00 " + "0" * 32 + " ffffffff 00000001 00000000 00200200 lo\n")
        self.assertEqual(procfs.default_route_interfaces(route, ipv6), {"br0", "eth1"})

    def test_a_reject_route_default_is_not_an_uplink(self):
        # `ip route add unreachable default metric …` has destination and mask "00000000" too, but
        # iface "*" and RTF_REJECT (0x0200) set. It must not count as a usable uplink.
        route = "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n" \
                "*\t00000000\t00000000\t0205\t0\t0\tFFFFFFFF\t00000000\n" \
                "eth0\t00000000\t0101A8C0\t0003\t0\t0\t0\t00000000\n"
        self.assertEqual(procfs.default_route_interfaces(route, ""), {"eth0"})

class Sockets(unittest.TestCase):
    def test_ss_tinp_gives_socket_ages_and_owners(self):
        socks = procfs.parse_ss_tinp(fixture("ss_tinp.txt"))
        self.assertEqual(len(socks), 2)
        for s in socks:
            self.assertEqual(s["state"], "ESTAB")
            self.assertIsInstance(s["lastsnd"], int)
            self.assertIsInstance(s["lastrcv"], int)
            self.assertEqual(len(s["procs"]), 1)
            self.assertEqual(s["procs"][0][0], "python3")
        self.assertNotEqual(socks[0]["local"], socks[0]["peer"])

    def test_an_idle_keepalive_has_old_last_send_and_receive(self):
        """The capture held two idle connections for 3+ s: the ages are what tells an idle keepalive (old)
        from an in-flight request (recent) in the plan's 3b-versus-4b question."""
        for s in procfs.parse_ss_tinp(fixture("ss_tinp.txt")):
            self.assertGreaterEqual(s["lastsnd"], 2000)
            self.assertGreaterEqual(s["lastrcv"], 2000)

    def test_a_header_only_or_empty_listing_is_no_sockets(self):
        self.assertEqual(procfs.parse_ss_tinp(""), [])
        self.assertEqual(procfs.parse_ss_tinp("State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n"), [])


if __name__ == "__main__":
    unittest.main(verbosity=1)

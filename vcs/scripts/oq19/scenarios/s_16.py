"""16: an idle box that is NOT quiet: sshd, cron and its housekeeping bursts running, the sampler at its real
cadence. IDLE. (The lifecycle shim of F7's closed loop is not built yet: T6/T7.)"""
import os
import subprocess

def SETUP(ctx):
    job = "* * * * * root python3 %s/burn.py --procs 1 --seconds 3 --duty 1 >/dev/null 2>&1\n" % ctx.tools
    if os.geteuid() == 0:  # the container: no daemons yet, start them
        os.makedirs("/run/sshd", exist_ok=True)
        ctx.spawn(["/usr/sbin/sshd", "-D", "-e"])
        with open("/etc/cron.d/oq19", "w") as f:
            f.write(job)
        os.chmod("/etc/cron.d/oq19", 0o644)
        ctx.spawn(["cron", "-f"])
    else:  # a real box (boxd): sshd and cron already run as system services; only the housekeeping job is ours
        subprocess.run(["sudo", "-n", "sh", "-c", "cat > /etc/cron.d/oq19 && chmod 644 /etc/cron.d/oq19"],
                       input=job, text=True, check=True)
    ctx.sleep(2.0)

ACTIONS = {}

# Release note draft: SSH hosts (#378)

- **Work on a server you already have.** Choose SSH when creating a workroom, enter your host and
  parent folder, and keep several workrooms on one Linux server. Each has its own terminals, Run
  command and port forwards. Deleting one removes its folder and sessions; the server stays.
- **Git sees your host's tools and credentials.** The app's Git commands on boxd, exe.dev,
  containers and SSH hosts now use the host user's login-shell environment.

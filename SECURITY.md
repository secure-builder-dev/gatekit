# Security

## Reporting a vulnerability

Please report it privately, not in a public issue.

1. Go to the **Security** tab of this repository.
2. Click **Report a vulnerability**.
3. Say what you found, how to reproduce it, and which gatekit version you're on
   (the first line of `.gatekit/VERSION`).

If that button isn't there, open an issue that says only "I have a security report" and a
maintainer will set up a private channel. Don't put details in the issue.

You should hear back within a week. Once a fix is released, the report is credited to you unless
you'd rather it wasn't.

## What counts

Gatekit runs on your machine and in your CI with access to your code, so these matter most:

- the install script (`install.sh`) or the self-updater fetching or running something it shouldn't
- a gatekit script running a command built from untrusted input, such as a file name, a branch
  name or a scanner's output
- a scan or review reporting PASS when it didn't run or didn't finish
- anything that sends your code, secrets or findings somewhere you didn't ask it to

A scanner missing a particular CVE is a matter for that scanner's own project (Trivy, Grype,
Checkov, hadolint, ClamAV), though it's still worth an ordinary issue here.

## Supported versions

Only the latest release gets fixes. Gatekit updates itself, so an install that has run recently
is on it.

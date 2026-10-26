## {release} beta {beta} "{codename}" (build {build})

**A prerelease for testing**, not a release: version {version}, built {date}, with what is coming in {release}, published so that it can be tried before it is released. GitHub marks it Pre-release and never Latest, so the project's download links keep serving the stable release. Codename **{codename}**, as every {release} build.

It follows the stable release [{stable}](https://github.com/corytron/c4-hue-driver/releases/tag/v{stable_version}). The changes below are everything since then: they are what to try.

### Changes since {stable_version}

{this_build}

### Install

Install every `.c4z` file of this prerelease at once through Driver ▸ "Add or Update Driver or Agent…" in Composer Pro, updating every device in place; never delete and re-add the Hue Bridge driver (that loses the pairing). When the changes above say a driver's capabilities changed, reboot the controller from System Manager afterwards: on OS 3.x, Composer's "Restart Director?" does not load them.

### Going back

Install every `.c4z` file of the [latest stable release](https://github.com/corytron/c4-hue-driver/releases/latest) the same way: all at once through "Add or Update Driver or Agent…", in place, never deleting the Hue Bridge driver. Going back to an older build has not been tested yet, so read the bridge's **Status** and **Lights** afterwards rather than assume. A driver that only this prerelease has is not among those files: delete its devices in Composer if you go back for good.

### Feedback

Report what you tried and what you saw with the [Beta feedback form](https://github.com/corytron/c4-hue-driver/issues/new?template=beta-feedback.yml), or tell the person who sent you this link. Replace LAN addresses and the bridge id with placeholders, and never paste a Hue application key.

### Verify a download

```sh
sha256sum -c SHA256SUMS.txt
for f in *.c4z; do gh attestation verify "$f" --repo corytron/c4-hue-driver --signer-workflow corytron/c4-hue-driver/.github/workflows/release.yml; done
```

`gh` 2.102.0 or newer, in the folder that holds every file of the prerelease. `manifest.json` names the build, the commit and each package's sha256.

### License

Apache License 2.0 (LICENSE and NOTICE travel inside each `.c4z`). Philips Hue and Hue are trademarks of Signify Holding B.V.; Control4 and Composer are trademarks of Snap One, LLC. This project is not affiliated with, endorsed by or supported by Signify or Snap One.

# 💿 Hanakai Release Machine

[latest-releases]: RELEASES.md
[release-gem-workflow]: https://github.com/hanakai-rb/release-machine/actions/workflows/release.yml
[release-npm-workflow]: https://github.com/hanakai-rb/release-machine/actions/workflows/release-npm.yml

Central GitHub Actions workflows to release Hanakai gems and npm packages using signed version tags.

**[See latest releases][latest-releases]**.

## How to release a gem

Prerequisites:

- You are an [authorized releaser](releasers.yml) for the gem.
- Your git is signing commits using your key [configured here](releasers/).

To release a gem:

1. Prepare `lib/[gem_name]/version.rb` and `CHANGELOG.md` for the new version.
2. Create a signed tag for the version: `get tag -s vX.Y.Z`
3. Push the signed tag: `git push origin vX.Y.Z`
4. Watch the latest [release workflow run][release-gem-workflow] to see the new version published.

You can also use the [gem-release gem](https://github.com/svenfuchs/gem-release) to streamline steps 1-3:

```
$ gem install gem-release
$ gem bump --version X.Y.Z --tag --sign --push
```

Check out `gem bump --help` to learn more.

## How to release an npm package

Prerequisites:

- You are an [authorized releaser](releasers.yml) for the package.
- Your git is signing commits using your key [configured here](releasers/).
- The package is configured on npmjs.com with a [trusted publisher](https://docs.npmjs.com/trusted-publishers) pointing at this repo's `release-npm.yml` workflow.

To release an npm package:

1. Prepare `package.json` and `CHANGELOG.md` for the new version.
2. Create a signed tag for the version: `git tag -s vX.Y.Z`
3. Push the signed tag: `git push origin vX.Y.Z`
4. Watch the latest [release workflow run][release-npm-workflow] to see the new version published.

## Configuring Release Machine

See [`.github/workflows/release.yml`](.github/workflows/release.yml) and [`.github/workflows/release-npm.yml`](.github/workflows/release-npm.yml) for the release workflows.

### [`releasers/`](releasers/)

Contains public keys for each releaser, expected to be used with signing version tags. These files names should match the releaser's GitHub username. For example:

- `t-boz.ssh.txt` (when signing commits with SSH)
- `left-eye.gpg.asc` (when signing commits with GPG)

### [`releasers.yml`](releasers.yml)

Defines who is authorized to release packages. Contains:

- **`default`**: Releasers authorized for all packages
- **`packages`**: Releasers for specific packages (in addition to `default` releasers)

Example:

```yaml
default:
  - t-boz
  - left-eye
packages:
  hanami-router:
    - chilli
```

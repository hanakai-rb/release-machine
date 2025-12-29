# 💿 Hanakai Release Machine

[latest-releases]: RELEASES.md
[release-workflow]: https://github.com/hanakai-rb/release-machine/actions/workflows/release.yml 

A central GitHub Actions workflow to release Hanakai gems using signed version tags.

**[See latest releases][latest-releases]**.

## How to release a gem

Prerequisites:

- You are an [authorized releaser](releasers.yml) for the gem.
- Your git is signing commits using your key [configured here](releasers/).

To release a gem:

1. Prepare `lib/[gem_name]/version.rb` and `CHANGELOG.md` for the new version.
2. Create a signed tag for the version: `get tag -s vX.Y.Z`
3. Push the signed tag: `git push origin vX.Y.Z`
4. Watch the latest [release workflow run][release-workflow] to see the new version published.

You can also use the [gem-release gem](https://github.com/svenfuchs/gem-release) to streamline steps 1-3:

```
$ gem install gem-release
$ gem bump --version X.Y.Z --tag --sign --push
```

Check out `gem bump --help` to learn more.

## Configuring Release Machine

See [`.github/workflows/release.yml`](.github/workflows/release.yml) for the release workflow.

### [`releasers/`](releasers/)

Contains public keys for each releaser, expected to be used with signing version tags. These files names should match the releaser's GitHub username. For example:

- `t-boz.ssh.txt` (when signing commits with SSH)
- `left-eye.gpg.asc` (when signing commits with GPG)

### [`releasers.yml`](releasers.yml)

Defines who is authorized to release gems. Contains:

- **`default`**: Releasers authorized for all gems
- **`gems`**: Releasers for specific gems (in addition to `default` releasers)

Example:

```yaml
default:
  - t-boz
  - left-eye
gems:
  hanami-router:
    - chilli
```

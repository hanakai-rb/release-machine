# 💿 Hanakai Release Machine

A central GitHub Actions workflow to release Hanakai gems using signed version tags.

## Config

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

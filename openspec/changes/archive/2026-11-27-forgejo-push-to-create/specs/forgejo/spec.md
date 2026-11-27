# Spec Delta

## ADDED Requirements

### Requirement: Repository creation on first push

An authenticated user with write access to a namespace SHALL be able to create a repository in that namespace by pushing to a path that does not yet exist, without going through the web UI or API. A push to a nonexistent path in a namespace the user may not write to SHALL be rejected and SHALL NOT create a repository. Push-created repositories SHALL be private unless the pusher explicitly opts out with the `repo.private` push option.

#### Scenario: First push creates a private repository in the user's namespace
- **WHEN** a signed-in user runs `git push` to a path such as `<user>/<name>.git` that does not yet exist
- **THEN** forgejo creates the repository `<user>/<name>`, the push succeeds, and the repository is private

#### Scenario: First push creates a private repository in an organization
- **WHEN** a user who is a member of an organization with permission to create repositories there pushes to `<org>/<name>.git`, a path that does not yet exist
- **THEN** forgejo creates the repository `<org>/<name>`, the push succeeds, and the repository is private

#### Scenario: Push to an organization without permission is rejected
- **WHEN** a user without repository-creation permission for an organization pushes to `<org>/<name>.git`, a path that does not exist
- **THEN** the push is rejected and no repository is created

#### Scenario: Push-created repository made public explicitly
- **WHEN** a user pushes to a nonexistent path with the push option `repo.private=false`
- **THEN** the repository is created and is not private

#### Scenario: Repository created on push honors write access, not anonymity
- **WHEN** an unauthenticated client attempts to push to a path that does not exist
- **THEN** authentication fails and no repository is created

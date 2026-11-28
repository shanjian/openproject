# TODO

## Release feature

### Remove the Release custom field seeder once deployments are provisioned
`ReleaseCustomFieldSeeder` (hooked into `RootSeeder`) exists only to provision the
"Release" work package custom field on existing/new deployments out of the box. It
re-creates the field on every `openproject configure` if one does not exist, which means
it would also re-create the field after an administrator deliberately deletes it.

Once existing deployments have been seeded (and the field is established), remove the
seeder and its `RootSeeder` hook. The custom field is data and will persist after the
seeder is removed.

- Files: `app/seeders/release_custom_field_seeder.rb`, the `seed_release_custom_field`
  hook in `app/seeders/root_seeder.rb`, and `spec/seeders/release_custom_field_seeder_spec.rb`
  (and revert the `CustomField.count` bumps in the standard/BIM root seeder specs).

### ~~Release workflow performance — move large releases to a background job~~ (done)
Implemented: `VersionsController#release` validates synchronously, then runs releases with
more than `RELEASE_ASYNC_THRESHOLD` (100) incomplete work packages via
`Versions::ReleaseJob` so the web request is not blocked. Smaller releases still run
synchronously for immediate feedback. Tune `RELEASE_ASYNC_THRESHOLD` if needed.

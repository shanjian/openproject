module OpenProject::GithubIntegration
  module Patches
    module API
      module WorkPackageRepresenter
        module_function

        def extension # rubocop:disable Metrics/AbcSize
          ->(*) do
            link :github,
                 cache_if: -> { current_user.allowed_in_work_package?(:show_github_content, represented) } do
              {
                href: "#{work_package_path(id: represented.id)}/tabs/github",
                title: "github"
              }
            end

            link :github_pull_requests do
              {
                href: api_v3_paths.github_pull_requests_by_work_package(represented.id),
                title: "GitHub pull requests"
              }
            end

            link :github_branches do
              next if represented.new_record?

              {
                href: api_v3_paths.github_branches_by_work_package(represented.id),
                title: "GitHub branches"
              }
            end
          end
        end
      end
    end
  end
end

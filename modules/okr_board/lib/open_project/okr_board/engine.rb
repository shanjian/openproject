# frozen_string_literal: true

module OpenProject::OkrBoard
  class Engine < ::Rails::Engine
    engine_name :openproject_okr_board

    include OpenProject::Plugins::ActsAsOpEngine

    register "openproject-okr_board",
             author_url: "https://www.openproject.org",
             bundled: true,
             settings: {} do
      project_module :okr_board, dependencies: :work_package_tracking, order: 81 do
        permission :show_okr_board,
                   { "okr_board/pages": %i[index] },
                   permissible_on: :project,
                   dependencies: :view_work_packages
      end

      menu :project_menu,
           :okr_board,
           { controller: "/okr_board/pages", action: :index },
           caption: :"okr_board.label_okr_board",
           after: :work_packages,
           icon: "op-view-timeline"
    end
  end
end

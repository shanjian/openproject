module OkrBoard
  class PagesController < ApplicationController
    before_action :find_project
    before_action :authorize
    before_action :authorize_work_package_permission, only: %i[index]

    def index
      if availability.available?
        render "index", layout: "angular/angular"
      else
        render "empty_state"
      end
    end

    private

    def find_project
      @project = Project.find(params[:project_id])
    end

    def availability
      @availability ||= OkrBoard::Availability.new(@project)
    end
    helper_method :availability

    def authorize_work_package_permission
      unless current_user.allowed_in_project?(:view_work_packages, @project)
        deny_access
      end
    end
  end
end

module OkrBoard
  class PagesController < ApplicationController
    before_action :find_project
    before_action :authorize

    def index
      render plain: "ok"
    end

    private

    def find_project
      @project = Project.find(params[:project_id])
    end
  end
end

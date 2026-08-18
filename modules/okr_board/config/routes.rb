Rails.application.routes.draw do
  scope "projects/:project_id", as: "project" do
    get "okr_board" => "okr_board/pages#index", as: "okr_board"
  end
end

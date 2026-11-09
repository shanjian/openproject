# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require "rails_helper"

RSpec.describe InplaceEditFieldsController do
  let(:user) { create(:user) }
  let(:model) { create(:project) }
  let(:attribute) { :description }
  let(:model_param) { "project" }

  let(:update_registry) do
    contract = double
    allow(contract).to receive(:new).and_return(double(writable?: true))
    registry = OpenProject::InplaceEdit::UpdateRegistry.new
    registry.register(Project, handler:, contract:)
    registry
  end

  before do
    allow(controller).to receive_messages(current_user: user, update_registry:)

    allow(Project)
      .to receive(:visible)
            .and_return(Project.all)
  end

  describe "GET #edit" do
    let(:handler) { double }

    it "returns a turbo stream response" do
      get :edit, params: {
        model: model_param,
        id: model.id,
        attribute:
      }, format: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    end
  end

  describe "PATCH #update" do
    let(:handler) { double(call: success) }

    context "when update is successful" do
      let(:success) { true }

      it "returns ok and renders success flash" do
        patch :update, params: {
          model: model_param,
          id: model.id,
          attribute:,
          project: {
            description: "New description"
          }
        }, format: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      end
    end

    context "when update fails" do
      let(:success) { false }

      it "returns unprocessable_entity and stays in edit mode" do
        patch :update, params: {
          model: model_param,
          id: model.id,
          attribute:,
          project: {
            description: ""
          }
        }, format: :turbo_stream

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      end
    end

    context "when no update handler is registered" do
      let(:handler) { nil }

      it "returns 404" do
        patch :update, params: {
          model: model_param,
          id: model.id,
          attribute:,
          project: { description: "Foo" }
        }, format: :turbo_stream

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST #reset" do
    let(:handler) { double }

    it "renders the component in view mode" do
      post :reset, params: {
        model: model_param,
        id: model.id,
        attribute:
      }, format: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    end
  end

  describe "attributes that are not registered for inplace editing" do
    let(:handler) { double }

    # The attribute name comes from the URL and ends up in `public_send`, so it must be rejected
    let(:actions) { %i[edit reset] }

    %w[destroy touch to_json name remove_owned_labels custom_field_1].each do |name|
      it "returns 404 for #{name} and does not call it on the model" do
        actions.each do |action|
          get action, params: { model: model_param, id: model.id, attribute: name }, format: :turbo_stream

          expect(response).to have_http_status(:not_found)
        end

        expect(Project).to exist(model.id)
      end
    end

    it "returns 404 on update" do
      patch :update, params: { model: model_param, id: model.id, attribute: "name", project: { name: "x" } },
                     format: :turbo_stream

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "system arguments" do
    let(:handler) { double }

    it "does not let the client override arguments the server sets" do
      allow(OpenProject::Common::InplaceEditFieldComponent).to receive(:new).and_call_original

      get :edit, params: {
        model: model_param,
        id: model.id,
        attribute:,
        system_arguments_json: { attribute: "destroy", model: "x", update_registry: "x", enforce_edit_mode: false,
                                 label: "kept" }.to_json
      }, format: :turbo_stream

      expect(response).to have_http_status(:ok)
      expect(OpenProject::Common::InplaceEditFieldComponent)
        .to have_received(:new)
              .with(hash_including(model:, attribute: attribute.to_sym, enforce_edit_mode: true, label: "kept"))
    end
  end

  describe "model resolution errors" do
    let(:handler) { double }

    it "returns 404 for unsupported model" do
      get :edit, params: {
        model: "invalid_model",
        id: 123,
        attribute:
      }, format: :turbo_stream

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for missing record" do
      get :edit, params: {
        model: model_param,
        id: -1,
        attribute:
      }, format: :turbo_stream

      expect(response).to have_http_status(:not_found)
    end
  end
end

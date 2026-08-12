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

require "spec_helper"

# The request specs in import_spec.rb assert the entry's position in the server-rendered HTML,
# which is necessary but not sufficient: the entry shipped in the right DOM position yet was
# invisible in the browser. The saved views sibling is `height: 100%` inside an `overflow: auto`
# container (frontend/src/global_styles/layout/_main_menu.sass), so it consumed the whole scroll
# viewport and pushed the trailing import entry exactly past the bottom edge -- present, "visible"
# to Capybara, and unreachable without scrolling the submenu. Only geometry catches that, so
# assert it here.
RSpec.describe "Import work packages menu entry visibility", :js do
  shared_let(:admin) { create(:admin) }

  let(:project) { create(:project) }

  before { login_as admin }

  it "renders inside the visible area of the work packages submenu" do
    visit project_work_packages_path(project)

    # The saved views live in a lazily loaded turbo-frame; its height is what squeezes the
    # import entry, so wait for it before measuring anything.
    expect(page).to have_css("#work_packages_sidemenu .op-submenu", wait: 20)
    expect(page).to have_css("li[data-name='work_packages_import']")

    geometry = page.evaluate_script(<<~JS)
      (() => {
        const ul = document.querySelector("li[data-name='work_packages'] > ul.main-menu--children");
        const item = ul.querySelector("li[data-name='work_packages_import']");
        const ulBox = ul.getBoundingClientRect();
        const itemBox = item.getBoundingClientRect();
        return {
          itemHeight: item.offsetHeight,
          // Allow a pixel of rounding slack at each edge.
          fullyInside: itemBox.top >= ulBox.top - 1 && itemBox.bottom <= ulBox.bottom + 1,
          overflowPx: Math.round(itemBox.bottom - ulBox.bottom)
        };
      })()
    JS

    expect(geometry["itemHeight"]).to be > 0
    expect(geometry["fullyInside"])
      .to be(true), "import entry overflows the submenu by #{geometry['overflowPx']}px"
  end

  # The bug is geometric, and a short window is the worst case: the saved views need more room
  # than they have, which is exactly when a `height: 100%` sibling would squeeze the entry out.
  it "stays inside the visible area in a short window" do
    page.current_window.resize_to(1280, 620)
    visit project_work_packages_path(project)

    expect(page).to have_css("#work_packages_sidemenu .op-submenu", wait: 20)

    geometry = page.evaluate_script(<<~JS)
      (() => {
        const ul = document.querySelector("li[data-name='work_packages'] > ul.main-menu--children");
        const item = ul.querySelector("li[data-name='work_packages_import']");
        const ulBox = ul.getBoundingClientRect();
        const itemBox = item.getBoundingClientRect();
        return {
          fullyInside: itemBox.top >= ulBox.top - 1 && itemBox.bottom <= ulBox.bottom + 1,
          overflowPx: Math.round(itemBox.bottom - ulBox.bottom)
        };
      })()
    JS

    expect(geometry["fullyInside"])
      .to be(true), "import entry overflows the submenu by #{geometry['overflowPx']}px at 1280x620"
  end

  it "still shows every saved view alongside it" do
    visit project_work_packages_path(project)

    expect(page).to have_css("#work_packages_sidemenu .op-submenu", wait: 20)

    within "li[data-name='work_packages'] > ul.main-menu--children" do
      expect(page).to have_link("All open")
      expect(page).to have_link(I18n.t("work_packages.import.menu_title"))
    end
  end
end

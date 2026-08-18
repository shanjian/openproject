Gem::Specification.new do |s|
  s.name        = "openproject-okr_board"
  s.version     = "1.0.0"
  s.authors     = "OpenProject GmbH"
  s.email       = "info@openproject.com"
  s.summary     = "OpenProject OKR Board"
  s.description = "Provides a filtered work package view for OKR Organization Unit and Version quick filters"
  s.license     = "GPLv3"

  s.files = Dir["{app,config,db,lib}/**/*"]
  s.metadata["rubygems_mfa_required"] = "true"
end

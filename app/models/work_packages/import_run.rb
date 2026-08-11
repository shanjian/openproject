module WorkPackages
  class ImportRun < ApplicationRecord
    self.table_name = "work_package_import_runs"

    belongs_to :project
    belongs_to :user

    enum :status, { queued: "queued", running: "running", succeeded: "succeeded", failed: "failed" },
                  default: "queued"

    validates :source, presence: true
  end
end

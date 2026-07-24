class ProjectChannel < ApplicationRecord
  belongs_to :project
  belongs_to :competitor_channel

  validates :competitor_channel_id, uniqueness: { scope: :project_id }
end

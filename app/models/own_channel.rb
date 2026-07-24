class OwnChannel < ApplicationRecord
  belongs_to :project

  validates :channel_url, presence: true,
            uniqueness: { scope: :project_id }
end

class Project < ApplicationRecord
  has_many :project_channels, dependent: :delete_all
  has_many :competitor_channels, through: :project_channels
  has_many :own_channels, dependent: :delete_all

  validates :name, presence: true, uniqueness: true
end

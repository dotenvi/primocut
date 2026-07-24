class ChannelSnapshot < ApplicationRecord
  belongs_to :competitor_channel

  validates :captured_at, presence: true
end

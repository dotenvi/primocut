# One ordered slot of a cut: a topic OR a manual time range (the PoC
# `CutItemRow`). Every item stores its own [start_s, end_s] — snapshotted from the
# topic for a topic item. `topic` is optional and nullified on the topic's
# deletion, so a topic item degrades into a preserved manual range.
class CutItem < ApplicationRecord
  belongs_to :cut
  belongs_to :topic, optional: true

  has_one :clip, dependent: :destroy
  has_many :cut_packagings, dependent: :destroy

  # A topic item carries its source topic; a manual range does not.
  def manual_range?
    topic_id.nil?
  end
end

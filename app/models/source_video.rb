# A YouTube video the user submitted for the source-videos pipeline (the PoC's
# `Video`). Never called a "live": the submitted source is a source_video.
class SourceVideo < ApplicationRecord
  belongs_to :project

  has_many :pipeline_jobs, dependent: :destroy
  has_one :transcript, dependent: :destroy
  has_one :chat_signal, dependent: :destroy

  # Statuses in which the video is actively being processed — not directly
  # deletable, and the pipeline treats them as "in flight". Mirrors the PoC
  # `models.py::ACTIVE_STATUSES`.
  ACTIVE_STATUSES = %w[queued downloading transcribing analyzing].freeze

  enum :status, {
    queued: "queued",
    downloading: "downloading",
    transcribing: "transcribing",
    analyzing: "analyzing",
    done: "done",
    error: "error",
    stopped: "stopped"
  }, default: "queued"

  validates :youtube_id, presence: true, uniqueness: true
  validates :url, presence: true

  scope :active, -> { where(status: ACTIVE_STATUSES) }

  def active?
    ACTIVE_STATUSES.include?(status)
  end
end

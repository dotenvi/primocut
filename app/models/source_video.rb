# A YouTube video the user submitted for the source-videos pipeline (the PoC's
# `Video`). Never called a "live": the submitted source is a source_video.
class SourceVideo < ApplicationRecord
  belongs_to :project

  has_many :pipeline_jobs, dependent: :destroy
  has_one :transcript, dependent: :destroy
  has_one :chat_signal, dependent: :destroy

  # The cut domain: LLM-selected topics, their per-video triage, the composed cuts
  # and the cached audience match.
  has_many :topics, dependent: :destroy
  has_many :topic_triages, dependent: :destroy
  has_many :cuts, dependent: :destroy
  has_one :audience_match, dependent: :destroy

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

  # The run whose progress the UI shows — the most recent one.
  def latest_job
    pipeline_jobs.order(:created_at).last
  end
end

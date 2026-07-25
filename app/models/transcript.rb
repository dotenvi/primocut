# The persisted transcript: the DB only stores; the shape lives in Ruby as
# Pipeline::Transcript, which the engine produces and the runner passes around.
# `segments` is the jsonb list of {index, start, end, text}.
class Transcript < ApplicationRecord
  belongs_to :source_video
end

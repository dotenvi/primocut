# The persisted chat signal (the DB only stores; the shape lives in Ruby as
# Pipeline::ChatSignals::Signal). `per_minute` is the jsonb list of
# {minute, msgs, laughs, emotes}; `peaks` the list of {ts, intensity, z}.
class ChatSignal < ApplicationRecord
  belongs_to :source_video
end

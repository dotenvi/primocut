module Pipeline
  # Chat signal detection: message density per minute, laughs/emotes and peaks.
  # Pure and deterministic (no network/GPU). Peaks are the minutes whose
  # messages-per-minute density stands out by z-score. Ported from the PoC
  # `chat/signals.py`.
  class ChatSignals
    Bucket = Data.define(:minute, :msgs, :laughs, :emotes)
    Peak = Data.define(:ts, :intensity, :z)
    Signal = Data.define(:per_minute, :peaks)

    # PT-BR laughs: "kkkk", "hahaha", "rsrsrs", "huehue", "aiai"…
    LAUGH_RE = /(k{3,}|(?:ha){2,}|(?:rs){2,}|(?:hue){1,}|(?:ai){2,}|lol)/i

    # Unicode emoji (most common ranges) — a reaction/emote marker. ❤ is U+2764.
    EMOJI_RE = /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{1F1E6}-\u{1F1FF}\u{2764}]/

    def self.laugh?(text)
      LAUGH_RE.match?(text.to_s)
    end

    def self.count_emotes(text)
      text.to_s.scan(EMOJI_RE).size
    end

    # Aggregate messages (anything responding to #offset_seconds and #text) into
    # per-minute buckets and detect peaks by z-score.
    def self.compute(messages, threshold: 2.0)
      return Signal.new(per_minute: [], peaks: []) if messages.empty?

      max_minute = messages.map { |m| (m.offset_seconds / 60).to_i }.max
      msgs = Array.new(max_minute + 1, 0)
      laughs = Array.new(max_minute + 1, 0)
      emotes = Array.new(max_minute + 1, 0)

      messages.each do |m|
        minute = (m.offset_seconds / 60).to_i
        msgs[minute] += 1
        laughs[minute] += 1 if laugh?(m.text)
        emotes[minute] += count_emotes(m.text)
      end

      buckets = (0..max_minute).map do |i|
        Bucket.new(minute: i, msgs: msgs[i], laughs: laughs[i], emotes: emotes[i])
      end
      Signal.new(per_minute: buckets, peaks: detect_peaks(buckets, threshold))
    end

    def self.detect_peaks(buckets, threshold)
      counts = buckets.map(&:msgs)
      return [] if counts.size < 2

      mean = counts.sum.to_f / counts.size
      # Population standard deviation (matches Python's statistics.pstdev).
      variance = counts.sum { |c| (c - mean)**2 } / counts.size
      std = Math.sqrt(variance)
      return [] if std.zero?

      buckets.filter_map do |b|
        z = (b.msgs - mean) / std
        Peak.new(ts: (b.minute * 60).to_f, intensity: b.msgs.to_f, z: z) if z >= threshold
      end
    end
  end
end

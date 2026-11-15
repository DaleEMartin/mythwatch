/// How commercial breaks are handled during playback (SPEC 5.1).
public enum CommercialSkipMode: String, Sendable, CaseIterable, Codable { case auto, prompt, off }

class NetworkCacheOptions {
  String key;
  bool enabled = false;
  Duration duration = Duration(days: 30);
  bool recoverFromException = false;
  bool encrypted = false;

  String get optimizedKey => "$key${encrypted ? "encrypted" : ""}";

  NetworkCacheOptions({
    this.key,
    this.enabled,
    this.duration,
    this.recoverFromException,
    this.encrypted,
  });
}

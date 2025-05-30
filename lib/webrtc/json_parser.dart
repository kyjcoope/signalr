typedef FromJson<T> = T Function(dynamic);

List<T> listFromJson<T>(dynamic json, FromJson fromJson) {
  var items = <T>[];
  if (json == null) return items;
  if (json is List) {
    for (var item in json) {
      items.add(fromJson(item));
    }
  } else {
    items.add(fromJson(json));
  }
  return items;
}

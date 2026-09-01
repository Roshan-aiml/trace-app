import 'package:flutter_test/flutter_test.dart';
import 'package:trace_mobile/api/api_client.dart';

void main() {
  test('base URL normalisation', () {
    expect(TraceApi.normalise('localhost:8000'), 'http://localhost:8000');
    expect(TraceApi.normalise('http://x:8000/'), 'http://x:8000');
    expect(TraceApi.normalise('https://api.example.com/'), 'https://api.example.com');
  });
}

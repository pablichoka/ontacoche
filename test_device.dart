import 'dart:convert';
import 'dart:io';

void main() async {
  final url =
      'https://ontacoche.vercel.app/api/device?selector=configuration.ident=009590067804';
  final response = await HttpClient().getUrl(Uri.parse(url)).then((req) {
    req.headers.add(
      'Authorization',
      'Bearer nLpE9t5i2qR1BxF3Y0zWcM8mX4yV7bK6jD#@vA%',
    );
    return req.close();
  });
  final body = await response.transform(utf8.decoder).join();
  // ignore: avoid_print
  print('Status: ${response.statusCode}');
  // ignore: avoid_print
  print('Body: $body');
}

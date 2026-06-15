import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  static const String baseUrl = 'https://glotalk.tech';
  static const String accessToken = 'glotalk2026';

  static Future<Map<String, dynamic>> verifyInvite(String code) async {
    final r = await http.post(Uri.parse('$baseUrl/invite/verify'),
      headers: {'Content-Type': 'application/json', 'x-glotalk-token': accessToken},
      body: jsonEncode({'code': code}));
    return jsonDecode(r.body);
  }

  static Future<Map<String, dynamic>> useInvite(String code) async {
    final r = await http.post(Uri.parse('$baseUrl/invite/use'),
      headers: {'Content-Type': 'application/json', 'x-glotalk-token': accessToken},
      body: jsonEncode({'code': code}));
    return jsonDecode(r.body);
  }

  static Future<Map<String, dynamic>> getLiveKitToken({
    required String room, required String identity, required String lang,
  }) async {
    final uri = Uri.parse('$baseUrl/livekit-token').replace(
      queryParameters: {'room': room, 'identity': identity, 'lang': lang});
    final r = await http.get(uri, headers: {'x-glotalk-token': accessToken});
    return jsonDecode(r.body);
  }
}

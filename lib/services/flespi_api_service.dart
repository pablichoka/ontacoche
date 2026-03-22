import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/device_message.dart';
import '../models/device_position.dart';
import '../models/geofence.dart';

class FlespiCommandExample {
  const FlespiCommandExample({
    required this.description,
    required this.properties,
  });

  final String description;
  final Map<String, dynamic> properties;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'description': description,
      'properties': properties,
    };
  }
}

class FlespiCommandDefinition {
  const FlespiCommandDefinition({
    required this.name,
    required this.description,
    required this.addresses,
    required this.schema,
    required this.examples,
    this.notes = const <String>[],
  });

  final String name;
  final String description;
  final List<String> addresses;
  final Map<String, dynamic> schema;
  final List<FlespiCommandExample> examples;
  final List<String> notes;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'description': description,
      'addresses': addresses,
      'schema': schema,
      'examples': examples.map((FlespiCommandExample example) => example.toJson()).toList(),
      'notes': notes,
    };
  }
}

class FlespiEndpointDefinition {
  const FlespiEndpointDefinition({
    required this.id,
    required this.method,
    required this.pathTemplate,
    required this.description,
    this.acceptsBody = false,
    this.recommendedFields = const <String>[],
    this.exampleBody,
  });

  final String id;
  final String method;
  final String pathTemplate;
  final String description;
  final bool acceptsBody;
  final List<String> recommendedFields;
  final Map<String, dynamic>? exampleBody;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'method': method,
      'pathTemplate': pathTemplate,
      'description': description,
      'acceptsBody': acceptsBody,
      'recommendedFields': recommendedFields,
      'exampleBody': exampleBody,
    };
  }
}

class FlespiDeviceCatalog {
  const FlespiDeviceCatalog({
    required this.ident,
    required this.protocolName,
    required this.deviceTypeName,
    required this.documentation,
    required this.commands,
    required this.readableEndpoints,
    this.notes = const <String>[],
  });

  final String ident;
  final String protocolName;
  final String deviceTypeName;
  final List<String> documentation;
  final List<FlespiCommandDefinition> commands;
  final List<FlespiEndpointDefinition> readableEndpoints;
  final List<String> notes;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'ident': ident,
      'protocol_name': protocolName,
      'device_type_name': deviceTypeName,
      'documentation': documentation,
      'commands': commands.map((FlespiCommandDefinition command) => command.toJson()).toList(),
      'readable_endpoints': readableEndpoints
          .map((FlespiEndpointDefinition endpoint) => endpoint.toJson())
          .toList(),
      'notes': notes,
    };
  }
}

class FlespiApiService {
  FlespiApiService({
    required this.baseUrl,
    required this.token,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String token;
  final http.Client _client;

  static const String defaultDeviceIdent = '009590067804';

  static const List<FlespiCommandDefinition> registeredCommands =
      <FlespiCommandDefinition>[
        FlespiCommandDefinition(
          name: 'custom',
          description: 'Send a raw text command to the tracker over its live connection.',
          addresses: <String>['connection'],
          schema: <String, dynamic>{
            'type': 'object',
            'required': <String>['payload'],
            'additionalProperties': false,
            'properties': <String, dynamic>{
              'payload': <String, dynamic>{
                'type': 'string',
                'title': 'Command payload',
              },
            },
          },
          examples: <FlespiCommandExample>[
            FlespiCommandExample(
              description: 'TKStar SG-style payload example from flespi docs.',
              properties: <String, dynamic>{'payload': '[SG*<ident>*0008*STOP,1]'},
            ),
            FlespiCommandExample(
              description: 'TKStar HQ-style payload example from flespi docs.',
              properties: <String, dynamic>{'payload': '*HQ,<ident>,S20,000000,1,1#'},
            ),
          ],
          notes: <String>[
            'This is the only command exposed by flespi for tkstar/jtk905_4g on this device.',
            'The payload is free-form text, so the app can send any vendor command string that the firmware accepts.',
            'Binary JT808 frames are not modeled by flespi for this device type.',
          ],
        ),
      ];

  static const List<FlespiEndpointDefinition> readableEndpoints =
      <FlespiEndpointDefinition>[
        FlespiEndpointDefinition(
          id: 'device-overview',
          method: 'GET',
          pathTemplate: '/gw/devices/{selector}',
          description: 'Read the main device object including configuration, telemetry, commands and settings.',
          recommendedFields: <String>[
            'id',
            'name',
            'connected',
            'last_active',
            'protocol_name',
            'device_type_name',
            'configuration',
            'telemetry',
            'settings',
            'commands',
          ],
        ),
        FlespiEndpointDefinition(
          id: 'telemetry-selector',
          method: 'GET',
          pathTemplate: '/gw/devices/{selector}/telemetry/{telemetrySelector}',
          description: 'Read latest telemetry values by selector list, for example position,server.timestamp,battery.level.',
        ),
        FlespiEndpointDefinition(
          id: 'messages',
          method: 'GET',
          pathTemplate: '/gw/devices/{selector}/messages',
          description: 'Read historical device messages from the message buffer.',
          acceptsBody: true,
          exampleBody: <String, dynamic>{
            'count': 50,
            'reverse': true,
            'fields': 'timestamp,server.timestamp,position.latitude,position.longitude,position.speed',
          },
        ),
        FlespiEndpointDefinition(
          id: 'logs',
          method: 'GET',
          pathTemplate: '/gw/devices/{selector}/logs',
          description: 'Read device logs including command lifecycle and connectivity events.',
          acceptsBody: true,
          exampleBody: <String, dynamic>{
            'count': 50,
            'reverse': true,
            'fields': 'timestamp,message,reason,level,command_id',
          },
        ),
        FlespiEndpointDefinition(
          id: 'commands-queue',
          method: 'GET',
          pathTemplate: '/gw/devices/{selector}/commands-queue/all',
          description: 'Read pending queued commands.',
        ),
        FlespiEndpointDefinition(
          id: 'commands-result',
          method: 'GET',
          pathTemplate: '/gw/devices/{selector}/commands-result',
          description: 'Read executed or expired commands.',
        ),
        FlespiEndpointDefinition(
          id: 'settings',
          method: 'GET',
          pathTemplate: '/gw/devices/{selector}/settings/all',
          description: 'Read current and pending settings exposed by flespi for the device.',
        ),
        FlespiEndpointDefinition(
          id: 'sms-preview',
          method: 'GET',
          pathTemplate: '/gw/devices/{selector}/sms',
          description: 'Read SMS rendering for commands when the protocol supports SMS transport.',
        ),
      ];

  static FlespiDeviceCatalog registeredCatalog({
    String ident = defaultDeviceIdent,
  }) {
    return FlespiDeviceCatalog(
      ident: ident,
      protocolName: 'tkstar',
      deviceTypeName: 'jtk905_4g',
      documentation: const <String>[
        'https://flespi.com/kb/commands-and-settings',
        'https://flespi.com/protocols/tkstar',
        'https://flespi.com/protocols/tkstar#commands',
        'https://flespi.com/devices/tk-star-jtk905-4g',
      ],
      commands: registeredCommands,
      readableEndpoints: readableEndpoints,
      notes: const <String>[
        'The runtime catalog should be fetched from /gw/devices/{selector}?fields=commands,settings,configuration,telemetry.',
        'For this device instance, flespi currently exposes one command only: custom(payload).',
      ],
    );
  }

  Map<String, String> get _headers {
    return <String, String>{
      'Authorization': 'FlespiToken $token',
      'Content-Type': 'application/json',
    };
  }

  Future<Map<String, dynamic>> getDevice(
    String selector, {
    List<String>? fields,
  }) async {
    return readDeviceEndpoint(
      selector: selector,
      relativePath: '',
      queryParameters: _fieldsQuery(fields),
    );
  }

  Future<Map<String, dynamic>> updateDevice(
    String selector,
    Map<String, dynamic> data,
  ) async {
    final Uri uri = Uri.parse('$baseUrl/gw/devices/$selector');
    final http.Response response = await _client.put(
      uri,
      headers: _headers,
      body: jsonEncode(data),
    );

    return _decodeResponse(response);
  }

  Future<Map<String, dynamic>> getTelemetry(
    String selector, {
    List<String> selectors = const <String>['position', 'battery.level'],
  }) async {
    final String telemetrySelector = selectors.join(',');
    return readDeviceEndpoint(
      selector: selector,
      relativePath: '/telemetry/$telemetrySelector',
    );
  }

  Future<DevicePosition?> getCurrentPosition(String selector) async {
    final Map<String, dynamic> response = await getTelemetry(
      selector,
      selectors: const <String>[
        'position',
        'position.speed',
        'timestamp',
        'server.timestamp',
        'battery.level',
      ],
    );

    final List<dynamic> result = response['result'] as List<dynamic>? ?? const <dynamic>[];
    if (result.isEmpty) {
      return null;
    }

    final Map<String, dynamic> payload = Map<String, dynamic>.from(result.first as Map);
    if (payload['position'] == null) {
      return null;
    }

    return DevicePosition.fromFlespiJson(payload);
  }

  Future<Map<String, dynamic>> getMessages(
    String selector, {
    int count = 100,
    bool reverse = true,
    List<String>? fields,
    String? filter,
  }) async {
    return readDeviceEndpoint(
      selector: selector,
      relativePath: '/messages',
      body: <String, dynamic>{
        'count': count,
        'reverse': reverse,
        if (fields != null && fields.isNotEmpty) 'fields': fields.join(','),
        if (filter != null && filter.isNotEmpty) 'filter': filter,
      },
    );
  }

  Future<DeviceMessageSnapshot?> getLatestPositionMessage(
    String selector, {
    int count = 1,
  }) async {
    final Map<String, dynamic> response = await getMessages(
      selector,
      count: count,
      reverse: true,
      filter: "exists('position.latitude') && exists('position.longitude')",
      fields: const <String>[
        'timestamp',
        'server.timestamp',
        'report.code',
        'position.latitude',
        'position.longitude',
        'position.altitude',
        'position.speed',
        'battery.level',
        'battery.voltage',
        'plugin.geofence.status',
        'plugin.geofence.name',
      ],
    );

    final List<dynamic> result = response['result'] as List<dynamic>? ?? const <dynamic>[];
    if (result.isEmpty) {
      return null;
    }

    return DeviceMessageSnapshot.fromJson(
      Map<String, dynamic>.from(result.first as Map),
    );
  }

  Future<Map<String, dynamic>> sendCommand(
    String selector, {
    required String commandName,
    required Map<String, dynamic> properties,
    bool queue = false,
    int? timeout,
    int? ttl,
    int? priority,
    int? maxAttempts,
    String? condition,
  }) async {
    final Uri uri = Uri.parse(
      "$baseUrl/gw/devices/$selector/${queue ? 'commands-queue' : 'commands'}",
    );
    final String body = jsonEncode(
      <Map<String, dynamic>>[
        <String, dynamic>{
          'name': commandName,
          'properties': properties,
          if (timeout != null) 'timeout': timeout,
          if (ttl != null) 'ttl': ttl,
          if (priority != null) 'priority': priority,
          if (maxAttempts != null) 'max_attempts': maxAttempts,
          if (condition != null && condition.isNotEmpty) 'condition': condition,
        },
      ],
    );

    final http.Response response = await _client.post(
      uri,
      headers: _headers,
      body: body,
    );

    return _decodeResponse(response);
  }

  Future<Map<String, dynamic>> sendCustomPayload(
    String selector,
    String payload, {
    bool queue = false,
    int? timeout,
    int? ttl,
  }) {
    return sendCommand(
      selector,
      commandName: 'custom',
      properties: <String, dynamic>{'payload': payload},
      queue: queue,
      timeout: timeout,
      ttl: ttl,
    );
  }

  Future<Map<String, dynamic>> getLogs(
    String selector, {
    int count = 100,
    bool reverse = true,
    List<String>? fields,
  }) {
    return readDeviceEndpoint(
      selector: selector,
      relativePath: '/logs',
      body: <String, dynamic>{
        'count': count,
        'reverse': reverse,
        if (fields != null && fields.isNotEmpty) 'fields': fields.join(','),
      },
    );
  }

  Future<Map<String, dynamic>> getCommandQueue(String selector) {
    return readDeviceEndpoint(
      selector: selector,
      relativePath: '/commands-queue/all',
    );
  }

  Future<Map<String, dynamic>> getCommandResults(
    String selector, {
    String? commandId,
  }) {
    final String suffix = commandId == null || commandId.isEmpty
        ? '/commands-result'
        : '/commands-result/$commandId';
    return readDeviceEndpoint(selector: selector, relativePath: suffix);
  }

  Future<Map<String, dynamic>> getSettings(
    String selector, {
    String settingSelector = 'all',
  }) {
    return readDeviceEndpoint(
      selector: selector,
      relativePath: '/settings/$settingSelector',
    );
  }

  Future<Map<String, dynamic>> getRegisteredCapabilities(String selector) async {
    final Map<String, dynamic> runtime = await getDevice(
      selector,
      fields: const <String>[
        'id',
        'name',
        'connected',
        'protocol_id',
        'protocol_name',
        'device_type_id',
        'device_type_name',
        'configuration',
        'commands',
        'settings',
        'telemetry',
      ],
    );

    return <String, dynamic>{
      'catalog': registeredCatalog(ident: _extractIdent(selector)).toJson(),
      'runtime': runtime,
    };
  }

  Future<Geofence?> getGeofence(int id) async {
    final response = await _client.get(
      Uri.parse('$baseUrl/gw/geofences/$id?fields=id,name,geometry'),
      headers: _headers,
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['result'] != null && data['result'].isNotEmpty) {
        return Geofence.fromJson(data['result'][0]);
      }
    }
    return null;
  }

  Future<List<Geofence>> getDeviceGeofences(String selector) async {
    final Map<String, dynamic> assignmentsResponse = await readPath(
      '/gw/devices/$selector/geofences/all',
      queryParameters: const <String, String>{
        'fields': 'geofence_id,name',
      },
    );

    final List<dynamic> assignments =
        assignmentsResponse['result'] as List<dynamic>? ?? const <dynamic>[];
    final List<int> geofenceIds = assignments
        .whereType<Map>()
        .map((Map item) => item['geofence_id'])
        .whereType<num>()
        .map((num id) => id.toInt())
        .toList(growable: false);

    if (geofenceIds.isEmpty) {
      return const <Geofence>[];
    }

    final Map<String, dynamic> geofencesResponse = await readPath(
      '/gw/geofences/${geofenceIds.join(',')}',
      queryParameters: const <String, String>{
        'fields': 'id,name,geometry',
      },
    );

    final List<dynamic> result = geofencesResponse['result'] as List<dynamic>? ?? const <dynamic>[];
    return result
        .whereType<Map>()
        .map((Map item) => Geofence.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> readDeviceEndpoint({
    required String selector,
    required String relativePath,
    Map<String, String>? queryParameters,
    Object? body,
  }) {
    return readPath(
      '/gw/devices/$selector$relativePath',
      queryParameters: queryParameters,
      body: body,
    );
  }

  Future<Map<String, dynamic>> readPath(
    String path, {
    Map<String, String>? queryParameters,
    Object? body,
  }) async {
    final Uri uri = Uri.parse('$baseUrl$path').replace(
      queryParameters: queryParameters == null || queryParameters.isEmpty
          ? null
          : queryParameters,
    );
    final http.Response response = await _sendRequest(
      method: 'GET',
      uri: uri,
      body: body,
    );
    return _decodeResponse(response);
  }

  Map<String, String>? _fieldsQuery(List<String>? fields) {
    if (fields == null || fields.isEmpty) {
      return null;
    }

    return <String, String>{'fields': fields.join(',')};
  }

  Future<http.Response> _sendRequest({
    required String method,
    required Uri uri,
    Object? body,
  }) async {
    if (body == null && method == 'GET') {
      return _client.get(uri, headers: _headers);
    }

    final http.Request request = http.Request(method, uri);
    request.headers.addAll(_headers);
    if (body != null) {
      request.body = body is String ? body : jsonEncode(body);
    }

    final http.StreamedResponse streamedResponse = await _client.send(request);
    return http.Response.fromStream(streamedResponse);
  }

  String _extractIdent(String selector) {
    const String prefix = 'configuration.ident=';
    if (selector.startsWith(prefix)) {
      return selector.substring(prefix.length);
    }

    return selector;
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    final dynamic decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FlespiApiException(
        statusCode: response.statusCode,
        message: decoded is Map<String, dynamic>
            ? decoded['error']?.toString() ?? response.body
            : response.body,
      );
    }

    if (decoded is Map<String, dynamic>) {
      return decoded;
    }

    return <String, dynamic>{'result': decoded};
  }

  void dispose() {
    _client.close();
  }
}

class FlespiApiException implements Exception {
  const FlespiApiException({
    required this.statusCode,
    required this.message,
  });

  final int statusCode;
  final String message;

  @override
  String toString() => 'FlespiApiException($statusCode): $message';
}
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:networking/networking/model/network_cache_options.dart';
import 'package:networking/networking/network_cache.dart';

import 'header.dart';
import 'model/error_model.dart';
import 'model/result_model.dart';
import 'network_config.dart';
import 'network_learning.dart';
import 'network_listener.dart';
import 'network_queue.dart';
import 'request_id.dart';
import 'serializable.dart';
import 'serializable_object.dart';

class GenericRequestObject<ResponseType extends Serializable> {
  Set<Header> _headers;
  ContentType _contentType;
  MethodType _methodType;
  Duration _timeout;
  Uri _uri;
  NetworkLearning _learning;
  NetworkConfig _config;
  NetworkListener _listener;
  dynamic _body;
  ResponseType _type;
  Set<Cookie> _cookies;
  bool _isParse;
  String body;
  NetworkCache _cache;

  final RequestId id = new RequestId();

  GenericRequestObject(
    this._methodType,
    this._learning,
    this._config, [
    this._body,
  ]) {
    _headers = new Set();
    _cookies = new Set();
    _isParse = false;
  }

  GenericRequestObject<ResponseType> url(String url) {
    _uri = Uri.parse(_config != null ? _config.baseUrl + url : url);
    return this;
  }

  GenericRequestObject<ResponseType> addHeaders(
      Set<Header> configHeaders, Iterable<Header> headers) {
    if (headers != null) {
      configHeaders.addAll(headers);
    }

    _headers = configHeaders;

    return this;
  }

  GenericRequestObject<ResponseType> addHeader(Header header) {
    if (header != null) {
      /// check same headers value. if some value income remove older value and update [header]
      if (_headers.contains(header)) {
        _headers.removeWhere((header) => header.key == header.key);
        print(_headers.length);
        _headers.add(header);
      } else {
        _headers.add(header);
      }
    }
    return this;
  }

  GenericRequestObject<ResponseType> addCookies(Iterable<Cookie> cookies) {
    if (cookies != null) {
      _cookies.addAll(cookies);
    }
    return this;
  }

  GenericRequestObject<ResponseType> addCookie(Cookie cookie) {
    if (cookie != null) {
      _cookies.add(cookie);
    }
    return this;
  }

  @Deprecated("Use query instead")
  GenericRequestObject<ResponseType> addQuery(String key, String value) {
    if (_uri.toString().contains("?")) {
      _uri = Uri.parse(_uri.toString() + "&$key=$value");
    } else {
      _uri = Uri.parse(_uri.toString() + "?$key=$value");
    }
    return this;
  }

  GenericRequestObject<ResponseType> addHeaderWithParameters(
      String key, String value) {
    var header = new Header(key, value);
    _headers.add(header);
    return this;
  }

  GenericRequestObject<ResponseType> contentType(ContentType contentType) {
    _contentType = contentType;
    return this;
  }

  GenericRequestObject<ResponseType> timeout(Duration timeout) {
    _timeout = timeout;
    return this;
  }

  GenericRequestObject<ResponseType> isParse(bool isParse) {
    _isParse = isParse;
    return this;
  }

  GenericRequestObject<ResponseType> listener(NetworkListener listener) {
    _listener = listener;
    return this;
  }

  GenericRequestObject<ResponseType> type(ResponseType type) {
    _type = type;
    return this;
  }

  GenericRequestObject<ResponseType> query(String key, String value) {
    var old = _uri.toString();
    var prefix = old.contains("?") ? "&" : "?";
    _uri = Uri.parse("$old$prefix$key=$value");
    return this;
  }

  GenericRequestObject<ResponseType> path(String path) {
    _uri = Uri.parse(_uri.toString() + "/$path");
    return this;
  }

  GenericRequestObject<ResponseType> cache({
    bool enabled,
    @required String key,
    Duration duration,
    bool recoverFromException,
    bool encrypted,
  }) {
    _cache = NetworkCache();
    _cache.options = NetworkCacheOptions(
      enabled: enabled,
      key: key,
      duration: duration,
      recoverFromException: recoverFromException,
      encrypted: encrypted ?? false,
    );

    return this;
  }

  Future<HttpClientRequest> _request() async {
    final client = HttpClient();
    client.connectionTimeout = _getRequestTimeLimit;
    switch (_methodType) {
      case MethodType.GET:
        return await client.getUrl(_uri);
      case MethodType.POST:
        return await client.postUrl(_uri);
      case MethodType.PUT:
        return await client.putUrl(_uri);
      case MethodType.DELETE:
        return await client.deleteUrl(_uri);
      case MethodType.UPDATE:
        return await client.patchUrl(_uri);
    }

    throw new Exception("Unknown method type");
  }

  Future<dynamic> fetch() async {
    var request;
    try {
      request = await _request();
      _cookies?.forEach((cookie) => request.cookies.add(cookie));
      _headers
          .forEach((header) => request.headers.add(header.key, header.value));

      if (_methodType == MethodType.POST || _methodType == MethodType.PUT) {
        request.headers.add(
          HttpHeaders.contentTypeHeader,
          _contentType == null
              ? ContentType.json.toString()
              : _contentType.toString(),
        );
        if (_body != null && body == null) {
          var model = json.encode(_body);
          var utf8Length = utf8.encode(model).length;

          request.headers.contentLength = utf8Length;

          if (_body is List) {
            if (_body.first is SerializableObject) {
              var mapList = _body
                  .map((SerializableObject item) => item.toJson())
                  .toList();
              var jsonMapList = json.encode(mapList);
              request.write(jsonMapList);
              body = jsonMapList;
            } else {
              throw ErrorDescription(
                  "Body list param does not have serializable object");
            }
          } else {
            body = model;
            request.write(body);
          }
        } else if (body.isNotEmpty) {
          request.headers.contentLength = utf8.encode(body).length;
          request.write(body);
        }
      }

      if (_cache != null && _cache.options.enabled && await _cache.has()) {
        return _cache.read<ResponseType>(
          uri: _uri,
          isParse: _isParse,
          learning: _learning,
          listener: _listener,
          type: _type,
        );
      }

      var response = await request.close().timeout(
        _getRequestTimeLimit,
        onTimeout: () {
          throw TimeoutException("Timeout");
        },
      );

      var buffer = new StringBuffer();
      var bytes = await consolidateHttpClientResponseBytes(response);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        ResultModel model = ResultModel();
        model.url = _uri.toString();

        if (response.cookies != null) {
          model.cookies = response.cookies;
        }

        try {
          model.result = utf8.decode(bytes);
          if (_isParse) {
            await request.done;
            return _learning.checkSuccess<ResponseType>(_listener, model);
          }

          buffer.write(String.fromCharCodes(bytes));

          if (buffer.isNotEmpty) {
            var body = json.decode(model.result);
            model.jsonString = buffer.toString();
            var serializable = (_type as SerializableObject);

            if (_cache != null && _cache.options.enabled) {
              _cache.save(bytes: bytes, duration: _cache.options.duration);
            }

            if (body is List)
              model.data = body
                  .map((data) => serializable.fromJson(data))
                  .cast<ResponseType>()
                  .toList();
            else if (body is Map)
              model.data = serializable.fromJson(body) as ResponseType;
            else
              model.data = body;
          }
        } catch (e) {
          String s = String.fromCharCodes(bytes);
          model.bodyBytes = new Uint8List.fromList(s.codeUnits);
          model.result = "";
          print(e);
        }

        await request.done;
        if (_learning != null)
          return _learning.checkSuccess<ResponseType>(_listener, model);
        else {
          _listener?.result(model);
          return model;
        }
      } else {
        await request.done;
        ErrorModel error = ErrorModel();
        error.description = response.reasonPhrase;
        error.statusCode = response.statusCode;
        error.raw = buffer.toString();
        error.request = this;

        if (_learning != null)
          return _learning.checkCustomError(_listener, error);
        else {
          _listener?.error(error);
          throw (error);
        }
      }
    } on SocketException catch (exception) {
      if (_cache != null &&
          _cache.options.enabled &&
          _cache.options.recoverFromException) {
        return _cache.read<ResponseType>(
          uri: _uri,
          isParse: _isParse,
          learning: _learning,
          listener: _listener,
          type: _type,
        );
      }

      return customErrorHandler(exception, NetworkErrorTypes.NETWORK_ERROR,
          request: request);
    } on TimeoutException catch (exception) {
      return customErrorHandler(exception, NetworkErrorTypes.TIMEOUT_ERROR,
          request: request);
    } catch (exception) {
      return customErrorHandler(exception, NetworkErrorTypes.TIMEOUT_ERROR,
          request: request);
    }
  }

  List fromJsonList(List json, dynamic model) {
    return json
        .map((fields) => model.fromJson(fields))
        .cast<ResponseType>()
        .toList();
  }

  Future<void> customErrorHandler(exception, NetworkErrorTypes types,
      {HttpClientRequest request}) async {
    await request?.done;
    ErrorModel error = ErrorModel();
    error.description = exception.message;
    error.type = types;
    error.request = this;

    _listener?.error(error);

    if (_learning != null)
      return await _learning.checkCustomError(_listener, error);
    else
      throw (error);
  }

  void enqueue() {
    NetworkQueue.instance.add(this);
  }

  Duration get _getRequestTimeLimit => _timeout != null
      ? _timeout
      : _config != null ? _config.timeout : Duration(minutes: 1);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GenericRequestObject &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

enum MethodType {
  GET,
  POST,
  PUT,
  DELETE,
  UPDATE,
}

enum NetworkErrorTypes {
  NO_CONNECTION_ERROR,
  TIMEOUT_ERROR,
  AUTH_FAILURE_ERROR,
  SERVER_ERROR,
  NETWORK_ERROR,
  PARSE_ERROR,
  CLIENT_ERROR,
}

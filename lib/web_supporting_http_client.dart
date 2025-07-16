import 'dart:async';
import 'package:http/http.dart';
import 'package:signalr_netcore/ihub_protocol.dart';
import 'errors.dart';
import 'signalr_http_client.dart';
import 'utils.dart';
import 'package:logging/logging.dart';

typedef OnHttpClientCreateCallback = void Function(Client httpClient);

class WebSupportingHttpClient extends SignalRHttpClient {
  // Properties

  final Client? _client;
  final Logger? _logger;
  final OnHttpClientCreateCallback? _httpClientCreateCallback;

  // Methods

  WebSupportingHttpClient(Client? httpClient, Logger? logger,
      {OnHttpClientCreateCallback? httpClientCreateCallback})
      : this._client = httpClient ?? Client(),
        this._logger = logger,
        this._httpClientCreateCallback = httpClientCreateCallback;

  Future<SignalRHttpResponse> send(SignalRHttpRequest request) {
    // Check that abort was not signaled before calling send
    if ((request.abortSignal != null) && request.abortSignal!.aborted!) {
      return Future.error(AbortError());
    }

    if ((request.method == null) || (request.method!.length == 0)) {
      return Future.error(new ArgumentError("No method defined."));
    }

    if ((request.url == null) || (request.url!.length == 0)) {
      return Future.error(new ArgumentError("No url defined."));
    }

    return Future<SignalRHttpResponse>(() async {
      final uri = Uri.parse(request.url!);

      if (_httpClientCreateCallback != null && _client != null) {
        _httpClientCreateCallback!(_client!);
      }

      final abortFuture = Future<void>(() {
        final completer = Completer<void>();
        if (request.abortSignal != null) {
          request.abortSignal!.onabort = () {
            if (!completer.isCompleted) completer.completeError(AbortError());
          };
        }
        return completer.future;
      });

      final isJson = request.content != null &&
          request.content is String &&
          (request.content as String).startsWith('{');

      var headers = MessageHeaders();

      headers.setHeaderValue('X-Requested-With', 'FlutterHttpClient');
      headers.setHeaderValue(
          'content-type',
          isJson
              ? 'application/json;charset=UTF-8'
              : 'text/plain;charset=UTF-8');

      headers.addMessageHeaders(request.headers);

      // Safely log content length without assuming type
      String contentLength = 'unknown';
      if (request.content is String) {
        contentLength = (request.content as String).length.toString();
      }
      
      _logger?.finest(
          "HTTP send: url '${request.url}', method: '${request.method}' content: '${request.content}' content length = '$contentLength' headers: '$headers'");

      try {
        if (_client == null) {
          throw ArgumentError("HTTP client is not initialized");
        }
        
        // Handle HTTP request and possible abort
        Response httpResp;
        try {
          // Create list of futures to race
          final List<Future<dynamic>> futures = [
            _sendHttpRequest(_client!, request, uri, headers),
            abortFuture
          ];
          
          // Wait for the first future to complete
          final index = await Future.any(
              futures.map((f) => f.then((value) => futures.indexOf(f))));
              
          // If abortFuture won the race
          if (index == 1) {
            throw AbortError();
          }
          
          // Otherwise get the HTTP response
          httpResp = await futures[0] as Response;
        } catch (abortError) {
          // If abortFuture completes with an error, rethrow it
          _logger?.info("Request aborted: ${abortError.toString()}");
          throw AbortError();
        }

        if (request.abortSignal != null) {
          request.abortSignal!.onabort = null;
        }

        if ((httpResp.statusCode >= 200) && (httpResp.statusCode < 300)) {
          Object content;
          final contentTypeHeader = httpResp.headers['content-type'];
          final isJsonContent = contentTypeHeader == null ||
              contentTypeHeader.startsWith('application/json');
          if (isJsonContent) {
            content = httpResp.body;
          } else {
            content = httpResp.body;
            // When using SSE and the uri has an 'id' query parameter the response is not evaluated, otherwise it is an error.
            if (isStringEmpty(uri.queryParameters['id'])) {
              throw ArgumentError(
                  "Response Content-Type not supported: $contentTypeHeader");
            }
          }

          return SignalRHttpResponse(httpResp.statusCode,
              statusText: httpResp.reasonPhrase, content: content);
        } else {
          throw HttpError(httpResp.reasonPhrase, httpResp.statusCode);
        }
      } catch (e) {
        _logger?.warning("HTTP request error: ${e.toString()}");
        return Future.error(e);
      }
    });
  }

  /// Sends an HTTP request using the provided client
  /// 
  /// @param httpClient The HTTP client to use
  /// @param request The SignalR HTTP request details
  /// @param uri The parsed URI
  /// @param headers The headers to include in the request
  /// @return A Future that resolves with the HTTP Response
  Future<Response> _sendHttpRequest(
    Client httpClient,
    SignalRHttpRequest request,
    Uri uri,
    MessageHeaders headers,
  ) {
    Future<Response> httpResponse;

    // Handle null method safely
    String method = (request.method ?? "").toLowerCase();
    
    switch (method) {
      case 'post':
        httpResponse =
            httpClient.post(uri, body: request.content, headers: headers.asMap);
        break;
      case 'put':
        httpResponse =
            httpClient.put(uri, body: request.content, headers: headers.asMap);
        break;
      case 'delete':
        httpResponse = httpClient.delete(uri,
            body: request.content, headers: headers.asMap);
        break;
      case 'get':
      default:
        httpResponse = httpClient.get(uri, headers: headers.asMap);
    }

    // Apply timeout if specified
    final hasTimeout = (request.timeout != null) && (0 < request.timeout!);
    if (hasTimeout) {
      httpResponse =
          httpResponse.timeout(
            Duration(milliseconds: request.timeout!),
            onTimeout: () => throw TimeoutError("Request timed out after ${request.timeout}ms")
          );
    }

    return httpResponse;
  }
}

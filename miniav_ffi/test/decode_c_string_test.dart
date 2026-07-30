// Tests for the _decodeCString helper used in MiniAVFFIPlatform.setLogCallback.
//
// The helper reads a null-terminated C string via FFI and decodes it with
// Utf8Decoder(allowMalformed: true) so that non-UTF-8 bytes from native log
// messages (device names, driver strings with Latin-1 chars) never cause a
// FormatException.  These tests verify both the happy path and the
// malformed-byte cases that motivated the fix.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Mirror of the private _decodeCString implementation in miniav_ffi.dart.
// Any change to the production helper must be reflected here.
// ---------------------------------------------------------------------------
String decodeCString(Pointer<Char> ptr) {
  if (ptr.address == 0) return '';
  final bytes = ptr.cast<Uint8>();
  var len = 0;
  while (bytes[len] != 0) len++;
  return const Utf8Decoder(
    allowMalformed: true,
  ).convert(Uint8List.view(bytes.asTypedList(len).buffer, 0, len));
}

// Allocates a native buffer containing [bytes] followed by a null terminator.
// Caller is responsible for freeing with [malloc.free].
Pointer<Char> _alloc(List<int> bytes) {
  final ptr = malloc<Uint8>(bytes.length + 1);
  for (var i = 0; i < bytes.length; i++) {
    ptr[i] = bytes[i] & 0xFF;
  }
  ptr[bytes.length] = 0;
  return ptr.cast<Char>();
}

void main() {
  group('decodeCString', () {
    // ------------------------------------------------------------------
    // Null / empty
    // ------------------------------------------------------------------
    test('null pointer (address 0) returns empty string', () {
      expect(decodeCString(Pointer.fromAddress(0)), equals(''));
    });

    test('empty C string (immediate null terminator) returns empty string', () {
      final ptr = _alloc([]);
      addTearDown(() => malloc.free(ptr));
      expect(decodeCString(ptr), equals(''));
    });

    // ------------------------------------------------------------------
    // Valid encodings
    // ------------------------------------------------------------------
    test('pure ASCII is decoded correctly', () {
      const input = 'Hello, World!';
      final ptr = _alloc(input.codeUnits);
      addTearDown(() => malloc.free(ptr));
      expect(decodeCString(ptr), equals(input));
    });

    test('valid UTF-8 multi-byte characters are decoded correctly', () {
      // 'café' → [0x63, 0x61, 0x66, 0xC3, 0xA9]
      const input = 'café';
      final ptr = _alloc(utf8.encode(input));
      addTearDown(() => malloc.free(ptr));
      expect(decodeCString(ptr), equals(input));
    });

    test('Unicode BMP character (euro sign U+20AC) is decoded correctly', () {
      // '€' → [0xE2, 0x82, 0xAC]
      const input = '€';
      final ptr = _alloc(utf8.encode(input));
      addTearDown(() => malloc.free(ptr));
      expect(decodeCString(ptr), equals(input));
    });

    // ------------------------------------------------------------------
    // Malformed / non-UTF-8 bytes — the core of the fix
    // ------------------------------------------------------------------
    test('isolated 0xFF byte does not throw (was the original crash)', () {
      // Before the fix, message.cast<Utf8>().toDartString() would throw:
      //   FormatException: Unexpected extension byte (at offset 0)
      final ptr = _alloc([0xFF]);
      addTearDown(() => malloc.free(ptr));
      expect(() => decodeCString(ptr), returnsNormally);
    });

    test('isolated continuation byte 0x80 does not throw', () {
      final ptr = _alloc([0x80]);
      addTearDown(() => malloc.free(ptr));
      expect(() => decodeCString(ptr), returnsNormally);
    });

    test('Latin-1 high bytes (0xFF 0xFE) do not throw', () {
      final ptr = _alloc([0xFF, 0xFE, 0x41]); // invalid, invalid, 'A'
      addTearDown(() => malloc.free(ptr));
      expect(() => decodeCString(ptr), returnsNormally);
      // The valid ASCII byte 'A' must survive regardless of replacement policy.
      expect(decodeCString(ptr), endsWith('A'));
    });

    test('mixed valid UTF-8 and invalid bytes does not throw', () {
      // 'OK' + 0xFF (bad byte) + 'Z'
      final bytes = [...utf8.encode('OK'), 0xFF, 0x5A]; // 0x5A = 'Z'
      final ptr = _alloc(bytes);
      addTearDown(() => malloc.free(ptr));
      expect(() => decodeCString(ptr), returnsNormally);
      final result = decodeCString(ptr);
      expect(result, startsWith('OK'));
      expect(result, endsWith('Z'));
    });

    test('multi-byte sequence truncated at null terminator does not throw', () {
      // Start of a 3-byte sequence but only one byte before the null — invalid.
      final ptr = _alloc([0xE2]); // first byte of '€' with no continuation
      addTearDown(() => malloc.free(ptr));
      expect(() => decodeCString(ptr), returnsNormally);
    });

    // ------------------------------------------------------------------
    // Documents why allowMalformed: false is insufficient
    // ------------------------------------------------------------------
    test(
      'Utf8Decoder(allowMalformed: false) throws on 0xFF — motivates fix',
      () {
        expect(
          () => const Utf8Decoder(
            allowMalformed: false,
          ).convert(Uint8List.fromList([0xFF])),
          throwsFormatException,
        );
      },
    );

    // ------------------------------------------------------------------
    // Null-terminator position
    // ------------------------------------------------------------------
    test('null terminator stops reading at the correct position', () {
      // Native layout: 'A', 'B', '\0', 'C', 'D'
      // Only 'AB' should be returned.
      final ptr = malloc<Uint8>(5);
      addTearDown(() => malloc.free(ptr));
      ptr[0] = 0x41; // 'A'
      ptr[1] = 0x42; // 'B'
      ptr[2] = 0x00; // null terminator
      ptr[3] = 0x43; // 'C' — beyond null, must NOT appear
      ptr[4] = 0x44; // 'D' — beyond null, must NOT appear
      expect(decodeCString(ptr.cast<Char>()), equals('AB'));
    });

    test('realistic MiniAV log message is decoded correctly', () {
      const line = '[MiniAV] Camera device opened successfully.\n';
      final ptr = _alloc(utf8.encode(line));
      addTearDown(() => malloc.free(ptr));
      expect(decodeCString(ptr), equals(line));
    });

    test('Windows device name with non-ASCII Latin-1 chars does not throw', () {
      // Simulate a device name like "Logitech Héros" where é = 0xE9 in Latin-1
      // (not valid as a standalone byte in UTF-8).
      final bytes = [...utf8.encode('Logitech H'), 0xE9, ...utf8.encode('ros')];
      final ptr = _alloc(bytes);
      addTearDown(() => malloc.free(ptr));
      expect(() => decodeCString(ptr), returnsNormally);
      final result = decodeCString(ptr);
      expect(result, startsWith('Logitech H'));
      expect(result, endsWith('ros'));
    });
  });

  // ---------------------------------------------------------------------------
  // String lifetime — regression tests for the dangling-pointer bug.
  //
  // Root cause: NativeCallable.listener posts arguments to the Dart event loop
  // asynchronously.  The Pointer<Char> was copied as a raw integer (address);
  // by the time Dart ran the closure the C stack buffer was gone, yielding
  // garbage bytes or truncated strings.
  //
  // Fix: C heap-allocates (malloc+memcpy) before calling the callback; Dart
  // reads the string then calls the free function (mgpuFreeLogMessage /
  // miniav_shim_free_log_message).
  // ---------------------------------------------------------------------------
  group('log callback string lifetime', () {
    test('decoded Dart string is independent of native buffer — '
        'overwriting native bytes does not corrupt the result', () {
      const full = '[MiniAV] Device opened: Logitech BRIO Ultra HD Webcam';
      final ptr = _alloc(utf8.encode(full));
      final dartStr = decodeCString(ptr);

      // Overwrite the native buffer — simulates the C stack frame being
      // reused after the callback-invoking function returns.
      final raw = ptr.cast<Uint8>();
      for (var i = 0; i < full.length; i++) {
        raw[i] = 0x00;
      }
      malloc.free(ptr);

      expect(dartStr, equals(full));
    });

    test('heap-copy pattern: allocate → decode → free preserves full message '
        '(simulates free_log_message called after decodeCString)', () {
      const msg =
          '[FFmpeg] Input #0, mp4, from "capture.mp4": 1920x1080 @ 30fps';
      final heapPtr = _alloc(utf8.encode(msg));

      final received = decodeCString(heapPtr);
      malloc.free(heapPtr); // pointer now invalid

      expect(received, equals(msg));
    });

    test(
      'FFmpeg log message with non-UTF-8 bytes decoded after free is intact',
      () {
        // FFmpeg can emit Latin-1 filenames in log output (e.g. on Windows).
        final bytes = [
          ...utf8.encode('[FFmpeg] Opening file: C:\\Users\\Jean-'),
          0xE9, // é in Latin-1
          ...utf8.encode('\\video.mp4'),
        ];
        final ptr = _alloc(bytes);
        final received = decodeCString(ptr);
        malloc.free(ptr);

        expect(received, startsWith('[FFmpeg] Opening file:'));
        expect(received, endsWith('\\video.mp4'));
      },
    );

    test('message exactly 2048 bytes decoded completely — '
        'no truncation at former shim stack-buffer boundary', () {
      // The old FFmpeg shim used char buf[2048].  A log line that fills the
      // buffer should arrive with every character intact.
      final content = '[FFmpeg] ' + 'x' * 2039;
      final ptr = _alloc(utf8.encode(content));
      addTearDown(() => malloc.free(ptr));
      final result = decodeCString(ptr);
      expect(result.length, equals(content.length));
      expect(result, equals(content));
    });

    test('async event-loop delay: Dart string decoded before free is intact '
        'when accessed after Future resolves', () async {
      const msg = '[MiniAV] Camera device opened successfully';
      final ptr = _alloc(utf8.encode(msg));

      String? received;
      await Future.microtask(() {
        received = decodeCString(ptr);
        malloc.free(ptr);
      });

      expect(received, equals(msg));
    });
  });
}

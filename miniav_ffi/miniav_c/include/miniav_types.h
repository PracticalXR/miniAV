#ifndef MINIAV_TYPES_H
#define MINIAV_TYPES_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- Result Codes ---
typedef enum {
  MINIAV_SUCCESS = 0,
  MINIAV_ERROR_UNKNOWN = -1,
  MINIAV_ERROR_INVALID_ARG = -2,
  MINIAV_ERROR_NOT_INITIALIZED = -3,
  MINIAV_ERROR_SYSTEM_CALL_FAILED = -4,
  MINIAV_ERROR_NOT_SUPPORTED = -5,
  MINIAV_ERROR_BUFFER_TOO_SMALL = -6,
  MINIAV_ERROR_INVALID_HANDLE = -7,
  MINIAV_ERROR_DEVICE_NOT_FOUND = -8,
  MINIAV_ERROR_DEVICE_BUSY = -9,
  MINIAV_ERROR_ALREADY_RUNNING = -10,
  MINIAV_ERROR_NOT_RUNNING = -11,
  MINIAV_ERROR_OUT_OF_MEMORY = -12,
  MINIAV_ERROR_TIMEOUT = -13,
  MINIAV_ERROR_DEVICE_LOST = -14,
  MINIAV_ERROR_FORMAT_NOT_SUPPORTED = -15,
  MINIAV_ERROR_INVALID_OPERATION = -16,
  MINIAV_ERROR_NOT_IMPLEMENTED = -17,
  MINIAV_ERROR_NOT_CONFIGURED = -18,
  MINIAV_ERROR_PORTAL_FAILED = -19,
  MINIAV_ERROR_STREAM_FAILED = -20,
  MINIAV_ERROR_PORTAL_CLOSED = -21,
  MINIAV_ERROR_USER_CANCELLED = -22,
  // The OS denied a required runtime permission (camera/microphone/screen
  // consent, Accessibility/Input Monitoring, ...). miniAV never triggers
  // permission PROMPTS itself — request permission app-side first, then
  // configure. Mobile backends map their platform denial errors here.
  MINIAV_ERROR_PERMISSION_DENIED = -23,
} MiniAVResultCode;

// --- Device Info ---
#define MINIAV_DEVICE_ID_MAX_LEN 256
#define MINIAV_DEVICE_NAME_MAX_LEN 256
#define MINIAV_VIDEO_FORMAT_MAX_PLANES 4

typedef struct {
  char device_id[MINIAV_DEVICE_ID_MAX_LEN]; // Platform-specific unique
                                            // identifier
  char name[MINIAV_DEVICE_NAME_MAX_LEN];    // Human-readable name (UTF-8)
  bool is_default; // True if this is the default device
} MiniAVDeviceInfo;

// --- Pixel Formats
typedef enum {
    MINIAV_PIXEL_FORMAT_UNKNOWN = 0,
    
    // --- Standard RGB Formats (8-bit) ---
    MINIAV_PIXEL_FORMAT_RGB24,          // 24-bit RGB (no alpha)
    MINIAV_PIXEL_FORMAT_BGR24,          // 24-bit BGR (no alpha)
    MINIAV_PIXEL_FORMAT_RGBA32,         // 32-bit RGBA (alpha in MSB)
    MINIAV_PIXEL_FORMAT_BGRA32,         // 32-bit BGRA (alpha in MSB)
    MINIAV_PIXEL_FORMAT_ARGB32,         // 32-bit ARGB (alpha in LSB)
    MINIAV_PIXEL_FORMAT_ABGR32,         // 32-bit ABGR (alpha in LSB)
    MINIAV_PIXEL_FORMAT_RGBX32,         // 32-bit RGB with padding (X = unused)
    MINIAV_PIXEL_FORMAT_BGRX32,         // 32-bit BGR with padding (X = unused)
    MINIAV_PIXEL_FORMAT_XRGB32,         // 32-bit RGB with leading padding
    MINIAV_PIXEL_FORMAT_XBGR32,         // 32-bit BGR with leading padding
    
    // --- Standard YUV Formats (8-bit) ---
    MINIAV_PIXEL_FORMAT_I420,           // Planar YUV 4:2:0 (YYYY... UU... VV...)
    MINIAV_PIXEL_FORMAT_YV12,           // Planar YUV 4:2:0 (YYYY... VV... UU...)
    MINIAV_PIXEL_FORMAT_NV12,           // Semi-planar YUV 4:2:0 (YYYY... UVUV...)
    MINIAV_PIXEL_FORMAT_NV21,           // Semi-planar YUV 4:2:0 (YYYY... VUVU...)
    MINIAV_PIXEL_FORMAT_YUY2,           // Packed YUV 4:2:2 (YUYV YUYV...)
    MINIAV_PIXEL_FORMAT_UYVY,           // Packed YUV 4:2:2 (UYVY UYVY...)
    
    // --- High-End RGB Formats ---
    MINIAV_PIXEL_FORMAT_RGB30,          // 30-bit RGB (10-bit per channel)
    MINIAV_PIXEL_FORMAT_RGB48,          // 48-bit RGB (16-bit per channel)
    MINIAV_PIXEL_FORMAT_RGBA64,         // 64-bit RGBA (16-bit per channel)
    MINIAV_PIXEL_FORMAT_RGBA64_HALF,    // 64-bit RGBA half-precision float
    MINIAV_PIXEL_FORMAT_RGBA128_FLOAT,  // 128-bit RGBA IEEE float
    
    // --- High-End YUV Formats ---
    MINIAV_PIXEL_FORMAT_YUV420_10BIT,   // 10-bit YUV 4:2:0
    MINIAV_PIXEL_FORMAT_YUV422_10BIT,   // 10-bit YUV 4:2:2
    MINIAV_PIXEL_FORMAT_YUV444_10BIT,   // 10-bit YUV 4:4:4
    
    // --- Grayscale Formats ---
    MINIAV_PIXEL_FORMAT_GRAY8,          // 8-bit grayscale
    MINIAV_PIXEL_FORMAT_GRAY16,         // 16-bit grayscale
    
    // --- Raw/Bayer Formats ---
    MINIAV_PIXEL_FORMAT_BAYER_GRBG8,    // 8-bit Bayer GRBG
    MINIAV_PIXEL_FORMAT_BAYER_RGGB8,    // 8-bit Bayer RGGB
    MINIAV_PIXEL_FORMAT_BAYER_BGGR8,    // 8-bit Bayer BGGR
    MINIAV_PIXEL_FORMAT_BAYER_GBRG8,    // 8-bit Bayer GBRG
    MINIAV_PIXEL_FORMAT_BAYER_GRBG16,   // 16-bit Bayer GRBG
    MINIAV_PIXEL_FORMAT_BAYER_RGGB16,   // 16-bit Bayer RGGB
    MINIAV_PIXEL_FORMAT_BAYER_BGGR16,   // 16-bit Bayer BGGR
    MINIAV_PIXEL_FORMAT_BAYER_GBRG16,   // 16-bit Bayer GBRG

    MINIAV_PIXEL_FORMAT_MJPEG,          // Motion JPEG (MJPEG)
    
    MINIAV_PIXEL_FORMAT_COUNT
} MiniAVPixelFormat;

// --- Audio Formats (Moved Here) ---
typedef enum {
  MINIAV_AUDIO_FORMAT_UNKNOWN = 0,
  MINIAV_AUDIO_FORMAT_U8,  // Unsigned 8-bit integer
  MINIAV_AUDIO_FORMAT_S16, // Signed 16-bit integer
  MINIAV_AUDIO_FORMAT_S32, // Signed 32-bit integer
  MINIAV_AUDIO_FORMAT_F32,  // 32-bit floating point
  MINIAV_AUDIO_FORMAT_F64 // 64-bit floating point
} MiniAVAudioFormat;

// --- Capture Target Type (for Screen Capture) ---
typedef enum {
  MINIAV_CAPTURE_TYPE_DISPLAY, // Capture an entire display/monitor
  MINIAV_CAPTURE_TYPE_WINDOW,  // Capture a specific window
  MINIAV_CAPTURE_TYPE_REGION // Capture a specific region of a display or window
} MiniAVCaptureType;

typedef enum {
  MINIAV_OUTPUT_PREFERENCE_CPU,
  MINIAV_OUTPUT_PREFERENCE_GPU
} MiniAVOutputPreference;

// -- Format Info Structs (Now after enums) ---
typedef struct {
  uint32_t width;
  uint32_t height;
  MiniAVPixelFormat pixel_format;
  uint32_t frame_rate_numerator;
  uint32_t frame_rate_denominator;
  MiniAVOutputPreference output_preference;
} MiniAVVideoInfo;

typedef struct {
  MiniAVAudioFormat format;
  uint32_t sample_rate;
  uint8_t channels;
  uint32_t num_frames;
} MiniAVAudioInfo;

typedef enum MiniAVLoopbackTargetType {
  MINIAV_LOOPBACK_TARGET_NONE,
  MINIAV_LOOPBACK_TARGET_SYSTEM_AUDIO,
  MINIAV_LOOPBACK_TARGET_PROCESS,
  MINIAV_LOOPBACK_TARGET_WINDOW
} MiniAVLoopbackTargetType;

typedef struct MiniAVLoopbackTargetInfo {
  MiniAVLoopbackTargetType type;
  union {
    uint32_t process_id;
    void *window_handle; // Platform-specific: HWND, NSWindow*, XID, etc.
    // char internal_target_id[256]; // Could be used if resolving from a
    // device_id
  } TARGETHANDLE;
} MiniAVLoopbackTargetInfo;

// --- Opaque Handles ---
typedef struct MiniAVCameraContext *MiniAVCameraContextHandle;
typedef struct MiniAVScreenContext *MiniAVScreenContextHandle;
typedef struct MiniAVAudioContext *MiniAVAudioContextHandle;
typedef struct MiniAVAudioOutputContext *MiniAVAudioOutputContextHandle;
typedef struct MiniAVLoopbackContext *MiniAVLoopbackContextHandle;
typedef struct MiniAVInputContext *MiniAVInputContextHandle;
typedef struct MiniAVInjectContext *MiniAVInjectContextHandle;

// --- Input Capture Types ---

// Input type bitmask for selecting which inputs to capture
typedef enum {
  MINIAV_INPUT_TYPE_KEYBOARD = 0x01,
  MINIAV_INPUT_TYPE_MOUSE = 0x02,
  MINIAV_INPUT_TYPE_GAMEPAD = 0x04,
  MINIAV_INPUT_TYPE_MOTION = 0x08,  // IMU / device motion (see MiniAVMotionEvent)
} MiniAVInputType;

// Keyboard action
typedef enum {
  MINIAV_KEY_ACTION_DOWN = 0,
  MINIAV_KEY_ACTION_UP = 1,
} MiniAVKeyAction;

// Mouse action
typedef enum {
  MINIAV_MOUSE_ACTION_MOVE = 0,
  MINIAV_MOUSE_ACTION_BUTTON_DOWN = 1,
  MINIAV_MOUSE_ACTION_BUTTON_UP = 2,
  MINIAV_MOUSE_ACTION_WHEEL = 3,
} MiniAVMouseAction;

// Mouse button identifiers
typedef enum {
  MINIAV_MOUSE_BUTTON_NONE = 0,
  MINIAV_MOUSE_BUTTON_LEFT = 1,
  MINIAV_MOUSE_BUTTON_RIGHT = 2,
  MINIAV_MOUSE_BUTTON_MIDDLE = 3,
  MINIAV_MOUSE_BUTTON_X1 = 4,
  MINIAV_MOUSE_BUTTON_X2 = 5,
} MiniAVMouseButton;

// Keyboard event
typedef struct {
  uint64_t timestamp_us;
  uint32_t key_code;      // Platform virtual key code
  uint32_t scan_code;     // Hardware scan code
  MiniAVKeyAction action;
} MiniAVKeyboardEvent;

// Mouse event. Used by BOTH input capture (source) and input injection (sink);
// for injection the same struct is replayed onto the local machine.
typedef struct {
  uint64_t timestamp_us;
  int32_t x;              // Absolute screen X
  int32_t y;              // Absolute screen Y
  int32_t delta_x;        // Relative movement X
  int32_t delta_y;        // Relative movement Y
  int32_t wheel_delta;    // Vertical scroll wheel delta (+ = up/away)
  int32_t wheel_delta_x;  // Horizontal scroll wheel delta (+ = right)
  MiniAVMouseAction action;
  MiniAVMouseButton button;
  // Capture always reports absolute coords, so it sets this true. For
  // injection: true = MOVE to absolute (x, y); false = MOVE by (delta_x,
  // delta_y). Ignored for BUTTON_* / WHEEL actions.
  bool is_absolute;
} MiniAVMouseEvent;

// Gamepad event
typedef struct {
  uint64_t timestamp_us;
  uint32_t gamepad_index;
  uint16_t buttons;       // Bitmask of pressed buttons
  int16_t left_stick_x;
  int16_t left_stick_y;
  int16_t right_stick_x;
  int16_t right_stick_y;
  uint8_t left_trigger;
  uint8_t right_trigger;
  bool connected;
} MiniAVGamepadEvent;

// --- Motion / IMU Types ---
//
// ONE canonical convention every backend converts to at its native boundary
// (see INPUT_LAYER_PLAN.md §1.5): gyro rad/s right-handed; accel m/s^2 including
// gravity (reaction-force sign, face-up z ~= +9.81); quaternions scalar-LAST
// [x, y, z, w], right-handed, gravity-down. `screen_orientation` is
// `orientation` remapped into the current display frame — the field the client
// parallax path consumes so tilt maps the same way in portrait and landscape.
// These structs mirror the Dart MiniAVMotionEvent field-for-field so ffigen
// binds them directly.

typedef struct {
  double x, y, z;
} MiniAVVec3;

typedef struct {
  double x, y, z, w;  // scalar-LAST
} MiniAVQuat;

// How the backend prepares `screen_orientation`.
typedef enum {
  MINIAV_MOTION_MODE_RAW_DEVICE_FRAME = 0,     // screen_orientation == orientation
  MINIAV_MOTION_MODE_FUSED_SCREEN_STABLE = 1,  // remapped into the display frame
} MiniAVMotionMode;

// Reference frame the fused attitude is relative to.
typedef enum {
  MINIAV_ATTITUDE_REF_RELATIVE_DRIFT_FREE = 0,  // relative to start, drift-free
  MINIAV_ATTITUDE_REF_ABSOLUTE_MAG_NORTH = 1,   // absolute, yaw referenced to N
} MiniAVAttitudeRef;

// Current display rotation. Values are ordinals (match the Dart enum), NOT
// degrees: 0=0deg, 1=90deg, 2=180deg, 3=270deg.
typedef enum {
  MINIAV_DISPLAY_ROTATION_0 = 0,
  MINIAV_DISPLAY_ROTATION_90 = 1,
  MINIAV_DISPLAY_ROTATION_180 = 2,
  MINIAV_DISPLAY_ROTATION_270 = 3,
} MiniAVDisplayRotation;

// A decoded IMU / motion sample. Field order mirrors Dart MiniAVMotionEvent.
typedef struct {
  uint64_t timestamp_us;         // A/V master clock, microseconds
  MiniAVVec3 gyro;               // rad/s, right-handed
  MiniAVVec3 accel;              // m/s^2, INCLUDES gravity
  MiniAVVec3 linear_accel;       // m/s^2, gravity removed (zero if un-fused)
  MiniAVVec3 gravity;            // m/s^2, gravity estimate
  MiniAVVec3 magnetometer;       // uT; valid only when has_magnetometer
  bool has_magnetometer;
  MiniAVQuat orientation;        // fused attitude, device frame
  MiniAVAttitudeRef ref;
  double heading_deg;            // 0..360 toward north; valid when has_heading
  bool has_heading;
  MiniAVQuat screen_orientation; // attitude remapped into the display frame
  MiniAVDisplayRotation display; // current display rotation
} MiniAVMotionEvent;

// Typed input callbacks
typedef void (*MiniAVKeyboardCallback)(const MiniAVKeyboardEvent *event,
                                       void *user_data);
typedef void (*MiniAVMouseCallback)(const MiniAVMouseEvent *event,
                                    void *user_data);
typedef void (*MiniAVGamepadCallback)(const MiniAVGamepadEvent *event,
                                      void *user_data);
typedef void (*MiniAVMotionCallback)(const MiniAVMotionEvent *event,
                                     void *user_data);

// Input configuration. NOTE: motion fields are APPENDED so existing
// keyboard/mouse/gamepad byte offsets are unchanged (ABI-additive).
typedef struct {
  uint32_t input_types;         // Bitmask of MiniAVInputType
  uint32_t mouse_throttle_hz;   // 0 = no throttle, default = 60
  uint32_t gamepad_poll_hz;     // 0 = default (60)
  MiniAVKeyboardCallback keyboard_callback;
  MiniAVMouseCallback mouse_callback;
  MiniAVGamepadCallback gamepad_callback;
  void *user_data;
  uint32_t motion_rate_hz;      // 0 = default (60); web/most sensors cap at 60
  MiniAVMotionMode motion_mode; // how screen_orientation is prepared
  MiniAVMotionCallback motion_callback;
} MiniAVInputConfig;

// --- Logging ---
typedef enum {
  MINIAV_LOG_LEVEL_TRACE = 0,
  MINIAV_LOG_LEVEL_DEBUG,
  MINIAV_LOG_LEVEL_INFO,
  MINIAV_LOG_LEVEL_WARN,
  MINIAV_LOG_LEVEL_ERROR,
  MINIAV_LOG_LEVEL_NONE
} MiniAVLogLevel;

// Receives formatted log messages when registered via MiniAV_SetLogCallback.
// OWNERSHIP: `message` is heap-allocated and OWNED BY THE RECEIVER — release
// it with MiniAV_Free once consumed. (It must outlive the call because
// receivers may dispatch it asynchronously to another thread, e.g. the Dart
// FFI shim's NativeCallable.listener.) May be invoked from any capture or
// worker thread.
typedef void (*MiniAVLogCallback)(MiniAVLogLevel level, const char *message,
                                  void *user_data);

#ifdef __cplusplus
}
#endif

#endif // MINIAV_TYPES_H
#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vibe_audio.h"
#include "vibe_board.h"
#include "vibe_roxy_assets.h"
#include "vibe_stick_config.h"
#include "button_gpio.h"
#include "cJSON.h"
#include "driver/gpio.h"
#include "driver/ledc.h"
#include "driver/spi_master.h"
#include "esp_check.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_http_client.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_st7789.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "vibe_stick_ui_assets.h"
#include "iot_button.h"
#include "lvgl.h"
#include "nvs_flash.h"

#define LCD_HOST SPI2_HOST
#define LCD_H_RES 135
#define LCD_V_RES 240
#define LCD_X_GAP 52
#define LCD_Y_GAP 40
#define LCD_PIXEL_CLOCK_HZ (20 * 1000 * 1000)
#define LCD_BACKLIGHT_PWM_HZ 5000
#define LCD_BACKLIGHT_PWM_MAX 255
#define LCD_BACKLIGHT_DEFAULT 150
#define LVGL_DRAW_BUF_LINES 24
#define LVGL_TICK_PERIOD_MS 10
#define LVGL_TASK_STACK_SIZE 8192
#define BATTERY_FILL_CHARGING_MAX_WIDTH 28
#define BATTERY_FILL_NORMAL_MAX_WIDTH 26
#define POWER_STATE_POLL_MS 2000
#define ALERT_SOUND_PENDING_CAPACITY 32
#define HTTP_JSON_RESPONSE_CAPACITY 2048
#define POST_RECORDING_ACTION_WINDOW_MS 30000

#define PIN_BUTTON_FRONT 11
#define PIN_BUTTON_SIDE 12
#define PIN_LCD_MOSI 39
#define PIN_LCD_SCK 40
#define PIN_LCD_DC 45
#define PIN_LCD_CS 41
#define PIN_LCD_RST 21
#define PIN_LCD_BL 38

static const char *TAG = "vibe_stick";

typedef enum {
    VIBE_STICK_EVENT_POLL_STATE,
    VIBE_STICK_EVENT_SHORT_PRESS,
    VIBE_STICK_EVENT_DOUBLE_CLICK,
    VIBE_STICK_EVENT_LONG_START,
    VIBE_STICK_EVENT_LONG_STOP,
    VIBE_STICK_EVENT_TOGGLE_VIEW,
} agent_event_type_t;

typedef struct {
    agent_event_type_t type;
} agent_event_t;

typedef struct {
    char time[8];
    bool wifi;
    bool ble;
    int battery;
    bool battery_valid;
    bool battery_charging;
    bool usb_powered;
    char alert_event_id[56];
    char alert_type[24];
    char alert_message[80];
} agent_state_t;

typedef struct {
    char status[24];
    char project[40];
    int active_conversations;
    int quota_5h;
    int quota_7d;
    bool quota_5h_valid;
    bool quota_7d_valid;
    char quota_updated_at[8];
    bool quota_stale;
} codex_display_state_t;

typedef struct {
    char *data;
    int capacity;
    int used;
    bool truncated;
} http_response_capture_t;

typedef struct {
    char event_id[56];
    char type[24];
} pending_alert_sound_t;

static QueueHandle_t s_event_queue;
static SemaphoreHandle_t s_lvgl_lock;
static bool s_wifi_connected;
static bool s_recording_overlay_visible;
static atomic_bool s_long_press_active;
static atomic_bool s_long_start_pending;
static atomic_bool s_long_stop_pending;
static char s_last_alert_event_id[56];
static char s_last_alert_type[24];
static bool s_alert_sound_baseline_ready;
static pending_alert_sound_t s_pending_alert_sounds[ALERT_SOUND_PENDING_CAPACITY];
static size_t s_pending_alert_sound_head;
static size_t s_pending_alert_sound_count;
static char s_recording_session_id[40];
static bool s_recording_audio_uploaded;
static int64_t s_post_recording_action_deadline_ms;
static bool s_pet_view_visible;
static vibe_roxy_state_t s_pet_animation_state = VIBE_ROXY_IDLE;
static size_t s_pet_frame_index;
static uint16_t *s_pet_framebuffer;

static lv_display_t *s_display;
static lv_obj_t *s_dashboard_view;
static lv_obj_t *s_pet_view;
static lv_obj_t *s_pet_canvas;
static lv_obj_t *s_pet_status_dot;
static lv_obj_t *s_pet_status_label;
static lv_obj_t *s_pet_active_count_label;
static lv_timer_t *s_pet_animation_timer;
static lv_obj_t *s_wifi_label;
static lv_obj_t *s_wifi_status_label;
static lv_obj_t *s_battery_label;
static lv_obj_t *s_battery_icon;
static lv_obj_t *s_battery_fill;
static lv_obj_t *s_battery_cap;
static lv_obj_t *s_battery_bolt;
static lv_obj_t *s_codex_icon;
static lv_obj_t *s_active_count_label;
static lv_obj_t *s_codex_label;
static lv_obj_t *s_status_dot;
static lv_obj_t *s_status_label;
static lv_obj_t *s_quota_5h_title_label;
static lv_obj_t *s_quota_7d_title_label;
static lv_obj_t *s_quota_5h_bar;
static lv_obj_t *s_quota_7d_bar;
static lv_obj_t *s_quota_5h_label;
static lv_obj_t *s_quota_7d_label;
static lv_obj_t *s_quota_status_label;
static lv_obj_t *s_recording_overlay;
static lv_obj_t *s_recording_wave_group;
static lv_obj_t *s_recording_wave_bars[5];
static lv_obj_t *s_recording_title;
static lv_obj_t *s_recording_hint;

static agent_state_t s_state = {
    .time = "--:--",
    .wifi = false,
    .ble = false,
    .battery = 0,
    .battery_valid = false,
    .battery_charging = false,
    .usb_powered = false,
    .alert_event_id = "",
    .alert_type = "NONE",
    .alert_message = "",
};

static codex_display_state_t s_codex_state = {
    .status = "OFFLINE",
    .project = "vibestick",
    .active_conversations = 0,
    .quota_5h = 0,
    .quota_7d = 0,
    .quota_5h_valid = false,
    .quota_7d_valid = false,
    .quota_updated_at = "",
    .quota_stale = false,
};

extern const lv_font_t vibe_stick_cn_16;
#define FONT_CN (&vibe_stick_cn_16)

static const lv_color_t s_codex_accent_color = LV_COLOR_MAKE(0x4d, 0x82, 0xff);

static const lv_point_precise_t s_battery_bolt_points[] = {
    {3, 0},
    {1, 3},
    {3, 3},
    {2, 7},
    {6, 2},
    {4, 2},
};

static void render_state(void);
static void handle_recording_stop(void);

static void queue_event(agent_event_type_t type)
{
    if (!s_event_queue) {
        return;
    }
    agent_event_t event = {.type = type};
    if (xQueueSend(s_event_queue, &event, 0) != pdTRUE) {
        ESP_LOGW(TAG, "event queue full; dropped type=%d", (int)type);
    }
}

static void lvgl_lock(void)
{
    if (s_lvgl_lock) {
        xSemaphoreTake(s_lvgl_lock, portMAX_DELAY);
    }
}

static void lvgl_unlock(void)
{
    if (s_lvgl_lock) {
        xSemaphoreGive(s_lvgl_lock);
    }
}

static void lvgl_tick_cb(void *arg)
{
    (void)arg;
    lv_tick_inc(LVGL_TICK_PERIOD_MS);
}

static void lvgl_task(void *arg)
{
    (void)arg;
    while (true) {
        lvgl_lock();
        uint32_t wait_ms = lv_timer_handler();
        lvgl_unlock();
        if (wait_ms < 5) {
            wait_ms = 5;
        }
        if (wait_ms > 250) {
            wait_ms = 250;
        }
        vTaskDelay(pdMS_TO_TICKS(wait_ms));
    }
}

static bool notify_lvgl_flush_ready(esp_lcd_panel_io_handle_t panel_io,
                                    esp_lcd_panel_io_event_data_t *edata,
                                    void *user_ctx)
{
    (void)panel_io;
    (void)edata;
    lv_display_flush_ready((lv_display_t *)user_ctx);
    return false;
}

static void lvgl_flush_cb(lv_display_t *display, const lv_area_t *area, uint8_t *px_map)
{
    esp_lcd_panel_handle_t panel = lv_display_get_user_data(display);
    int32_t width = area->x2 - area->x1 + 1;
    int32_t height = area->y2 - area->y1 + 1;
    lv_draw_sw_rgb565_swap(px_map, width * height);
    esp_lcd_panel_draw_bitmap(panel, area->x1, area->y1, area->x2 + 1, area->y2 + 1, px_map);
}

static void set_backlight(uint8_t brightness)
{
    ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, brightness);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0);
}

static void init_backlight(void)
{
    ledc_timer_config_t timer = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .timer_num = LEDC_TIMER_0,
        .duty_resolution = LEDC_TIMER_8_BIT,
        .freq_hz = LCD_BACKLIGHT_PWM_HZ,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ESP_ERROR_CHECK(ledc_timer_config(&timer));
    ledc_channel_config_t channel = {
        .gpio_num = PIN_LCD_BL,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel = LEDC_CHANNEL_0,
        .timer_sel = LEDC_TIMER_0,
        .duty = 0,
        .hpoint = 0,
    };
    ESP_ERROR_CHECK(ledc_channel_config(&channel));
    set_backlight(LCD_BACKLIGHT_DEFAULT);
}

static esp_err_t init_display(void)
{
    init_backlight();

    spi_bus_config_t buscfg = {
        .sclk_io_num = PIN_LCD_SCK,
        .mosi_io_num = PIN_LCD_MOSI,
        .miso_io_num = -1,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = LCD_H_RES * LVGL_DRAW_BUF_LINES * sizeof(lv_color_t),
    };
    ESP_RETURN_ON_ERROR(spi_bus_initialize(LCD_HOST, &buscfg, SPI_DMA_CH_AUTO), TAG, "spi bus");

    esp_lcd_panel_io_handle_t io_handle = NULL;
    esp_lcd_panel_io_spi_config_t io_config = {
        .dc_gpio_num = PIN_LCD_DC,
        .cs_gpio_num = PIN_LCD_CS,
        .pclk_hz = LCD_PIXEL_CLOCK_HZ,
        .lcd_cmd_bits = 8,
        .lcd_param_bits = 8,
        .spi_mode = 0,
        .trans_queue_depth = 10,
        .on_color_trans_done = notify_lvgl_flush_ready,
        .user_ctx = NULL,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_HOST, &io_config, &io_handle),
                        TAG, "panel io");

    esp_lcd_panel_handle_t panel = NULL;
    esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = PIN_LCD_RST,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_st7789(io_handle, &panel_config, &panel), TAG, "panel");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_reset(panel), TAG, "panel reset");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_init(panel), TAG, "panel init");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_invert_color(panel, true), TAG, "panel invert");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_set_gap(panel, LCD_X_GAP, LCD_Y_GAP), TAG, "panel gap");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_disp_on_off(panel, true), TAG, "panel on");

    lv_init();
    s_display = lv_display_create(LCD_H_RES, LCD_V_RES);
    lv_display_set_user_data(s_display, panel);
    lv_display_set_flush_cb(s_display, lvgl_flush_cb);

    size_t buffer_size = LCD_H_RES * LVGL_DRAW_BUF_LINES * sizeof(lv_color_t);
    void *buf = heap_caps_malloc(buffer_size, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    ESP_RETURN_ON_FALSE(buf != NULL, ESP_ERR_NO_MEM, TAG, "lvgl buffer");
    lv_display_set_buffers(s_display, buf, NULL, buffer_size, LV_DISPLAY_RENDER_MODE_PARTIAL);
    esp_lcd_panel_io_callbacks_t callbacks = {
        .on_color_trans_done = notify_lvgl_flush_ready,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_panel_io_register_event_callbacks(io_handle, &callbacks, s_display),
                        TAG, "panel cb");

    const esp_timer_create_args_t tick_args = {
        .callback = lvgl_tick_cb,
        .name = "lvgl_tick",
    };
    esp_timer_handle_t tick_timer = NULL;
    ESP_RETURN_ON_ERROR(esp_timer_create(&tick_args, &tick_timer), TAG, "tick timer");
    ESP_RETURN_ON_ERROR(esp_timer_start_periodic(tick_timer, LVGL_TICK_PERIOD_MS * 1000), TAG, "tick start");

    BaseType_t task_created = xTaskCreate(lvgl_task, "lvgl", LVGL_TASK_STACK_SIZE,
                                          NULL, 3, NULL);
    ESP_RETURN_ON_FALSE(task_created == pdPASS, ESP_ERR_NO_MEM, TAG, "lvgl task");
    return ESP_OK;
}

static lv_obj_t *make_label(lv_obj_t *parent, const char *text, const lv_font_t *font,
                            lv_color_t color, int32_t width, lv_text_align_t align)
{
    lv_obj_t *label = lv_label_create(parent);
    lv_label_set_text(label, text);
    lv_obj_set_style_text_font(label, font, 0);
    lv_obj_set_style_text_color(label, color, 0);
    lv_label_set_long_mode(label, LV_LABEL_LONG_CLIP);
    lv_obj_set_width(label, width);
    lv_obj_set_style_text_align(label, align, 0);
    return label;
}

static lv_obj_t *make_bar(lv_obj_t *parent, int32_t width)
{
    lv_obj_t *bar = lv_bar_create(parent);
    lv_obj_set_size(bar, width, 5);
    lv_bar_set_range(bar, 0, 100);
    lv_obj_set_style_radius(bar, 3, 0);
    lv_obj_set_style_bg_color(bar, lv_color_hex(0x2a2d33), 0);
    lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(bar, lv_color_hex(0xf4f5f7), LV_PART_INDICATOR);
    lv_obj_set_style_radius(bar, 3, LV_PART_INDICATOR);
    return bar;
}

static lv_obj_t *make_plain_obj(lv_obj_t *parent, int32_t w, int32_t h,
                                lv_color_t color, lv_opa_t opa, int32_t radius)
{
    lv_obj_t *obj = lv_obj_create(parent);
    lv_obj_remove_style_all(obj);
    lv_obj_set_size(obj, w, h);
    lv_obj_set_style_bg_color(obj, color, 0);
    lv_obj_set_style_bg_opa(obj, opa, 0);
    lv_obj_set_style_radius(obj, radius, 0);
    return obj;
}

static void create_codex_icon(lv_obj_t *parent)
{
    s_codex_icon = lv_image_create(parent);
    lv_image_set_src(s_codex_icon, &vibe_stick_provider_codex_icon_40);
    lv_obj_align(s_codex_icon, LV_ALIGN_TOP_LEFT, 7, 52);
}

static const char *status_text_for(const char *status)
{
    if (strcmp(status, "RUNNING") == 0) {
        return "运行中";
    }
    if (strcmp(status, "DONE") == 0) {
        return "已完成";
    }
    if (strcmp(status, "APPROVAL") == 0) {
        return "待确认";
    }
    if (strcmp(status, "ERROR") == 0) {
        return "出错";
    }
    if (strcmp(status, "OFFLINE") == 0) {
        return "离线";
    }
    if (strcmp(status, "IDLE") == 0 || strcmp(status, "UNKNOWN") == 0) {
        return "待命";
    }
    return "待命";
}

static vibe_roxy_state_t roxy_state_for_status(const char *status)
{
    if (strcmp(status, "RUNNING") == 0) {
        return VIBE_ROXY_RUNNING;
    }
    if (strcmp(status, "APPROVAL") == 0) {
        return VIBE_ROXY_WAITING;
    }
    if (strcmp(status, "DONE") == 0) {
        return VIBE_ROXY_DONE;
    }
    if (strcmp(status, "ERROR") == 0) {
        return VIBE_ROXY_ERROR;
    }
    return VIBE_ROXY_IDLE;
}

static bool render_roxy_frame(size_t frame_index)
{
    if (!s_pet_canvas || !s_pet_framebuffer) {
        return false;
    }
    if (!vibe_roxy_decode_frame(s_pet_animation_state, frame_index,
                                s_pet_framebuffer, VIBE_ROXY_FRAME_PIXELS)) {
        ESP_LOGW(TAG, "failed to decode Roxy state=%d frame=%u",
                 (int)s_pet_animation_state, (unsigned)frame_index);
        return false;
    }
    s_pet_frame_index = frame_index;
    lv_obj_invalidate(s_pet_canvas);
    return true;
}

static void pet_animation_timer_cb(lv_timer_t *timer)
{
    (void)timer;
    if (!s_pet_view_visible) {
        return;
    }
    const size_t frame_count = vibe_roxy_frame_count(s_pet_animation_state);
    if (frame_count == 0) {
        return;
    }
    (void)render_roxy_frame((s_pet_frame_index + 1) % frame_count);
}

static void set_roxy_animation_state(vibe_roxy_state_t state)
{
    if (state == s_pet_animation_state && s_pet_framebuffer) {
        return;
    }
    s_pet_animation_state = state;
    if (s_pet_animation_timer) {
        uint32_t period_ms = vibe_roxy_frame_duration_ms(state);
        lv_timer_set_period(s_pet_animation_timer, period_ms > 0 ? period_ms : 300);
        lv_timer_reset(s_pet_animation_timer);
    }
    (void)render_roxy_frame(0);
}

static void set_pet_view_visible(bool visible)
{
    lvgl_lock();
    s_pet_view_visible = visible;
    if (visible) {
        lv_obj_add_flag(s_dashboard_view, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(s_pet_view, LV_OBJ_FLAG_HIDDEN);
        (void)render_roxy_frame(0);
        if (s_pet_animation_timer) {
            lv_timer_reset(s_pet_animation_timer);
        }
    } else {
        lv_obj_add_flag(s_pet_view, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(s_dashboard_view, LV_OBJ_FLAG_HIDDEN);
    }
    lvgl_unlock();
    ESP_LOGI(TAG, "display view=%s", visible ? "roxy" : "dashboard");
}

static void create_pet_view(lv_obj_t *screen)
{
    s_pet_view = make_plain_obj(screen, LCD_H_RES, LCD_V_RES,
                                lv_color_hex(0x050608), LV_OPA_TRANSP, 0);
    lv_obj_remove_flag(s_pet_view, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_align(s_pet_view, LV_ALIGN_CENTER, 0, 0);

    s_pet_framebuffer = heap_caps_malloc(VIBE_ROXY_FRAME_PIXELS * sizeof(uint16_t),
                                         MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_pet_framebuffer) {
        s_pet_framebuffer = heap_caps_malloc(VIBE_ROXY_FRAME_PIXELS * sizeof(uint16_t),
                                             MALLOC_CAP_8BIT);
    }
    ESP_ERROR_CHECK(s_pet_framebuffer ? ESP_OK : ESP_ERR_NO_MEM);
    ESP_ERROR_CHECK(vibe_roxy_decode_frame(VIBE_ROXY_IDLE, 0, s_pet_framebuffer,
                                           VIBE_ROXY_FRAME_PIXELS)
                        ? ESP_OK
                        : ESP_FAIL);
    s_pet_canvas = lv_canvas_create(s_pet_view);
    lv_canvas_set_buffer(s_pet_canvas, s_pet_framebuffer,
                         VIBE_ROXY_FRAME_WIDTH, VIBE_ROXY_FRAME_HEIGHT,
                         LV_COLOR_FORMAT_RGB565);
    lv_obj_align(s_pet_canvas, LV_ALIGN_TOP_MID, 0, 58);

    lv_obj_t *status_card = make_plain_obj(s_pet_view, LCD_H_RES - 16, 42,
                                           lv_color_hex(0x0e1014), LV_OPA_COVER, 8);
    lv_obj_set_style_border_width(status_card, 1, 0);
    lv_obj_set_style_border_color(status_card, lv_color_hex(0x22252b), 0);
    lv_obj_align(status_card, LV_ALIGN_TOP_MID, 0, 174);
    s_pet_status_dot = make_plain_obj(status_card, 7, 7, lv_color_hex(0x9aa0aa),
                                      LV_OPA_COVER, LV_RADIUS_CIRCLE);
    s_pet_status_label = make_label(status_card, "待命", FONT_CN,
                                    lv_color_hex(0xf3f4f6), 48, LV_TEXT_ALIGN_CENTER);
    lv_obj_align(s_pet_status_label, LV_ALIGN_CENTER, 0, 0);
    lv_obj_align_to(s_pet_status_dot, s_pet_status_label,
                    LV_ALIGN_OUT_LEFT_MID, -8, 0);
    s_pet_active_count_label = make_label(status_card, "", &lv_font_montserrat_12,
                                          lv_color_hex(0x9aa0aa), 28, LV_TEXT_ALIGN_RIGHT);
    lv_obj_align(s_pet_active_count_label, LV_ALIGN_RIGHT_MID, -9, 0);
    lv_obj_add_flag(s_pet_active_count_label, LV_OBJ_FLAG_HIDDEN);

    s_pet_animation_timer = lv_timer_create(
        pet_animation_timer_cb, vibe_roxy_frame_duration_ms(VIBE_ROXY_IDLE), NULL);
    ESP_ERROR_CHECK(s_pet_animation_timer ? ESP_OK : ESP_ERR_NO_MEM);
    lv_obj_add_flag(s_pet_view, LV_OBJ_FLAG_HIDDEN);
}

static void set_battery_ui(int battery_value, bool battery_valid,
                           bool charging, bool usb_powered)
{
    if (battery_value < 0) {
        battery_value = 0;
    } else if (battery_value > 100) {
        battery_value = 100;
    }

    char battery[8];
    if (battery_valid) {
        snprintf(battery, sizeof(battery), "%d%%", battery_value);
    } else {
        snprintf(battery, sizeof(battery), "--%%");
    }
    lv_label_set_text(s_battery_label, battery);

    const bool external_power = charging || usb_powered;
    const int fill_max_width = external_power
        ? BATTERY_FILL_CHARGING_MAX_WIDTH
        : BATTERY_FILL_NORMAL_MAX_WIDTH;
    int fill_width = battery_value > 0
        ? (battery_value * fill_max_width) / 100
        : 0;
    if (fill_width < 1 && battery_value > 0) {
        fill_width = 1;
    }

    const lv_color_t normal_color = lv_color_hex(0xf3f4f6);
    const lv_color_t charging_color = lv_color_hex(0x32d583);

    lv_obj_set_style_border_color(s_battery_icon, normal_color, 0);
    lv_obj_set_style_bg_color(s_battery_fill, external_power ? charging_color : normal_color, 0);
    lv_obj_set_style_bg_color(s_battery_cap, normal_color, 0);
    lv_obj_set_size(s_battery_fill, fill_width, external_power ? 14 : 12);
    lv_obj_set_style_radius(s_battery_fill, external_power ? 3 : 2, 0);
    lv_obj_align(s_battery_fill, LV_ALIGN_LEFT_MID, external_power ? 0 : 1, 0);

    if (s_battery_bolt) {
        if (external_power) {
            lv_obj_clear_flag(s_battery_bolt, LV_OBJ_FLAG_HIDDEN);
        } else {
            lv_obj_add_flag(s_battery_bolt, LV_OBJ_FLAG_HIDDEN);
        }
    }
}

static void wave_bar_height_cb(void *obj, int32_t height)
{
    lv_obj_set_height((lv_obj_t *)obj, height);
}

static void stop_recording_wave(void)
{
    static const int heights[5] = {14, 22, 32, 22, 14};
    for (int i = 0; i < 5; ++i) {
        if (s_recording_wave_bars[i]) {
            lv_anim_delete(s_recording_wave_bars[i], NULL);
            lv_obj_set_height(s_recording_wave_bars[i], heights[i]);
        }
    }
}

static void start_recording_wave(void)
{
    static const int min_heights[5] = {10, 14, 18, 14, 10};
    static const int max_heights[5] = {24, 34, 48, 34, 24};
    stop_recording_wave();
    for (int i = 0; i < 5; ++i) {
        if (!s_recording_wave_bars[i]) {
            continue;
        }
        lv_anim_t anim;
        lv_anim_init(&anim);
        lv_anim_set_var(&anim, s_recording_wave_bars[i]);
        lv_anim_set_values(&anim, min_heights[i], max_heights[i]);
        lv_anim_set_duration(&anim, 460);
        lv_anim_set_playback_duration(&anim, 460);
        lv_anim_set_delay(&anim, i * 70);
        lv_anim_set_repeat_count(&anim, LV_ANIM_REPEAT_INFINITE);
        lv_anim_set_exec_cb(&anim, wave_bar_height_cb);
        lv_anim_start(&anim);
    }
}

static void create_ui(void)
{
    lv_obj_t *screen = lv_display_get_screen_active(s_display);
    lv_obj_set_style_bg_color(screen, lv_color_hex(0x050608), 0);
    lv_obj_set_style_pad_all(screen, 0, 0);

    s_wifi_label = make_label(screen, "WiFi", &lv_font_montserrat_12,
                              lv_color_hex(0xf3f4f6), 44, LV_TEXT_ALIGN_LEFT);
    lv_obj_align(s_wifi_label, LV_ALIGN_TOP_LEFT, 8, 7);
    s_wifi_status_label = make_label(screen, "OFF", &lv_font_montserrat_12,
                                     lv_color_hex(0x686e78), 44, LV_TEXT_ALIGN_LEFT);
    lv_obj_align(s_wifi_status_label, LV_ALIGN_TOP_LEFT, 8, 23);

    s_battery_label = make_label(screen, "--%", &lv_font_montserrat_12,
                                 lv_color_hex(0xf3f4f6), 34, LV_TEXT_ALIGN_RIGHT);
    lv_obj_align(s_battery_label, LV_ALIGN_TOP_RIGHT, -42, 7);
    s_battery_icon = make_plain_obj(screen, 30, 16, lv_color_hex(0x000000), LV_OPA_TRANSP, 4);
    lv_obj_set_style_border_width(s_battery_icon, 1, 0);
    lv_obj_set_style_border_color(s_battery_icon, lv_color_hex(0xf3f4f6), 0);
    lv_obj_align(s_battery_icon, LV_ALIGN_TOP_RIGHT, -7, 7);
    s_battery_fill = make_plain_obj(s_battery_icon, 1, 12, lv_color_hex(0xf3f4f6), LV_OPA_COVER, 2);
    lv_obj_align(s_battery_fill, LV_ALIGN_LEFT_MID, 2, 0);
    s_battery_bolt = lv_line_create(s_battery_icon);
    lv_line_set_points(s_battery_bolt, s_battery_bolt_points,
                       sizeof(s_battery_bolt_points) / sizeof(s_battery_bolt_points[0]));
    lv_obj_set_style_line_width(s_battery_bolt, 2, 0);
    lv_obj_set_style_line_color(s_battery_bolt, lv_color_hex(0xffffff), 0);
    lv_obj_set_style_line_rounded(s_battery_bolt, true, 0);
    lv_obj_align(s_battery_bolt, LV_ALIGN_CENTER, 0, 0);
    lv_obj_add_flag(s_battery_bolt, LV_OBJ_FLAG_HIDDEN);
    s_battery_cap = make_plain_obj(screen, 3, 8, lv_color_hex(0xf3f4f6), LV_OPA_COVER, 1);
    lv_obj_align_to(s_battery_cap, s_battery_icon, LV_ALIGN_OUT_RIGHT_MID, 1, 0);

    s_dashboard_view = make_plain_obj(screen, LCD_H_RES, LCD_V_RES,
                                      lv_color_hex(0x050608), LV_OPA_TRANSP, 0);
    lv_obj_remove_flag(s_dashboard_view, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_align(s_dashboard_view, LV_ALIGN_CENTER, 0, 0);

    create_codex_icon(s_dashboard_view);

    s_status_dot = lv_obj_create(s_dashboard_view);
    lv_obj_remove_style_all(s_status_dot);
    lv_obj_set_size(s_status_dot, 7, 7);
    lv_obj_set_style_radius(s_status_dot, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(s_status_dot, lv_color_hex(0xf3f4f6), 0);
    lv_obj_set_style_bg_opa(s_status_dot, LV_OPA_COVER, 0);
    lv_obj_align(s_status_dot, LV_ALIGN_TOP_LEFT, 65, 80);
    s_active_count_label = make_label(s_status_dot, "1", &lv_font_montserrat_10,
                                      lv_color_hex(0x050608), 18, LV_TEXT_ALIGN_CENTER);
    lv_obj_align(s_active_count_label, LV_ALIGN_CENTER, 0, 0);
    lv_obj_add_flag(s_active_count_label, LV_OBJ_FLAG_HIDDEN);

    s_codex_label = make_label(s_dashboard_view, "Codex", &lv_font_montserrat_16, lv_color_hex(0xf3f4f6), 60, LV_TEXT_ALIGN_LEFT);
    lv_obj_align(s_codex_label, LV_ALIGN_TOP_LEFT, 65, 51);

    s_status_label = make_label(s_dashboard_view, "待命", FONT_CN, lv_color_hex(0xf3f4f6), 52, LV_TEXT_ALIGN_LEFT);
    lv_obj_align(s_status_label, LV_ALIGN_TOP_LEFT, 75, 73);

    lv_obj_t *quota_wrap = make_plain_obj(s_dashboard_view, LCD_H_RES - 16, 104, lv_color_hex(0x0e1014), LV_OPA_COVER, 8);
    lv_obj_set_style_border_width(quota_wrap, 1, 0);
    lv_obj_set_style_border_color(quota_wrap, lv_color_hex(0x22252b), 0);
    lv_obj_align(quota_wrap, LV_ALIGN_TOP_MID, 0, 118);

    lv_obj_t *divider = make_plain_obj(quota_wrap, 1, 72, lv_color_hex(0x242832), LV_OPA_COVER, 1);
    lv_obj_align(divider, LV_ALIGN_CENTER, 0, 10);

    s_quota_5h_title_label = make_label(s_dashboard_view, "5H --%", &lv_font_montserrat_12,
                                        lv_color_hex(0x8a9099), 44, LV_TEXT_ALIGN_CENTER);
    lv_obj_align(s_quota_5h_title_label, LV_ALIGN_TOP_LEFT, 17, 133);
    s_quota_5h_label = make_label(s_dashboard_view, "--%", &lv_font_montserrat_20, lv_color_hex(0xf3f4f6), 54, LV_TEXT_ALIGN_CENTER);
    lv_obj_align(s_quota_5h_label, LV_ALIGN_TOP_LEFT, 10, 153);
    s_quota_5h_bar = make_bar(s_dashboard_view, 46);
    lv_obj_align(s_quota_5h_bar, LV_ALIGN_TOP_LEFT, 16, 190);

    s_quota_7d_title_label = make_label(s_dashboard_view, "7D --%", &lv_font_montserrat_12,
                                        lv_color_hex(0x8a9099), 44, LV_TEXT_ALIGN_CENTER);
    lv_obj_align(s_quota_7d_title_label, LV_ALIGN_TOP_RIGHT, -17, 133);
    s_quota_7d_label = make_label(s_dashboard_view, "--%", &lv_font_montserrat_20, lv_color_hex(0xf3f4f6), 54, LV_TEXT_ALIGN_CENTER);
    lv_obj_align(s_quota_7d_label, LV_ALIGN_TOP_RIGHT, -10, 153);
    s_quota_7d_bar = make_bar(s_dashboard_view, 46);
    lv_obj_align(s_quota_7d_bar, LV_ALIGN_TOP_RIGHT, -16, 190);
    s_quota_status_label = make_label(s_dashboard_view, "WAIT", &lv_font_montserrat_10,
                                      lv_color_hex(0x686e78), 84, LV_TEXT_ALIGN_CENTER);
    lv_obj_align(s_quota_status_label, LV_ALIGN_TOP_MID, 0, 207);
    lv_obj_add_flag(s_quota_status_label, LV_OBJ_FLAG_HIDDEN);

    create_pet_view(screen);

    s_recording_overlay = lv_obj_create(screen);
    lv_obj_set_size(s_recording_overlay, LCD_H_RES, LCD_V_RES);
    lv_obj_align(s_recording_overlay, LV_ALIGN_CENTER, 0, 0);
    lv_obj_set_style_radius(s_recording_overlay, 0, 0);
    lv_obj_set_style_bg_color(s_recording_overlay, lv_color_hex(0x050608), 0);
    lv_obj_set_style_bg_opa(s_recording_overlay, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(s_recording_overlay, 0, 0);
    lv_obj_add_flag(s_recording_overlay, LV_OBJ_FLAG_HIDDEN);

    s_recording_wave_group = lv_obj_create(s_recording_overlay);
    lv_obj_remove_style_all(s_recording_wave_group);
    lv_obj_set_size(s_recording_wave_group, 82, 58);
    lv_obj_set_flex_flow(s_recording_wave_group, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(s_recording_wave_group, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(s_recording_wave_group, 6, 0);
    lv_obj_align(s_recording_wave_group, LV_ALIGN_CENTER, 0, -34);
    static const int initial_wave_heights[5] = {14, 22, 32, 22, 14};
    for (int i = 0; i < 5; ++i) {
        s_recording_wave_bars[i] = make_plain_obj(s_recording_wave_group, 6, initial_wave_heights[i],
                                                  lv_color_hex(0xf4f5f7), LV_OPA_COVER, 3);
    }

    s_recording_title = make_label(s_recording_overlay, "正在聆听", FONT_CN,
                                   lv_color_hex(0xf4f5f7), 120, LV_TEXT_ALIGN_CENTER);
    lv_obj_align(s_recording_title, LV_ALIGN_CENTER, 0, 22);
    s_recording_hint = make_label(s_recording_overlay, "松开识别", FONT_CN,
                                  lv_color_hex(0x8b9098), 120, LV_TEXT_ALIGN_CENTER);
    lv_obj_align(s_recording_hint, LV_ALIGN_BOTTOM_MID, 0, -22);
}

static void set_quota_label(lv_obj_t *bar, lv_obj_t *label, int value, bool valid, lv_color_t accent_color)
{
    lv_obj_set_style_bg_color(bar, valid ? accent_color : lv_color_hex(0x4b4f57), LV_PART_INDICATOR);
    if (!valid) {
        lv_bar_set_value(bar, 0, LV_ANIM_OFF);
        lv_label_set_text(label, "--%");
        return;
    }
    lv_bar_set_value(bar, value, LV_ANIM_OFF);
    char text[8];
    snprintf(text, sizeof(text), "%d%%", value);
    lv_label_set_text(label, text);
}

static void set_quota_title(lv_obj_t *label, const char *prefix, bool stale)
{
    if (stale) {
        char text[8];
        snprintf(text, sizeof(text), "%s*", prefix);
        lv_label_set_text(label, text);
    } else {
        lv_label_set_text(label, prefix);
    }
}

static void set_status_color(const char *status)
{
    lv_color_t color = lv_color_hex(0x9aa0aa);
    if (strcmp(status, "RUNNING") == 0 || strcmp(status, "DONE") == 0) {
        color = s_codex_accent_color;
    } else if (strcmp(status, "APPROVAL") == 0) {
        color = lv_color_hex(0xcfd3da);
    } else if (strcmp(status, "IDLE") == 0 || strcmp(status, "UNKNOWN") == 0) {
        color = lv_color_hex(0x9aa0aa);
    } else if (strcmp(status, "ERROR") == 0 || strcmp(status, "OFFLINE") == 0) {
        color = lv_color_hex(0x686e78);
    }
    lv_obj_set_style_bg_color(s_status_dot, color, 0);
    if (s_pet_status_dot) {
        lv_obj_set_style_bg_color(s_pet_status_dot, color, 0);
    }
}

static void render_state(void)
{
    lvgl_lock();
    const codex_display_state_t *display_state = &s_codex_state;
    const bool q5_valid = display_state->quota_5h_valid;
    const bool q7_valid = display_state->quota_7d_valid;
    const bool quota_stale = display_state->quota_stale;

    lv_label_set_text(s_wifi_label, "WiFi");
    lv_obj_set_style_text_color(s_wifi_label, lv_color_hex(0xf3f4f6), 0);
    if (s_wifi_connected) {
        lv_obj_add_flag(s_wifi_status_label, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_clear_flag(s_wifi_status_label, LV_OBJ_FLAG_HIDDEN);
    }
    set_battery_ui(s_state.battery, s_state.battery_valid,
                   s_state.battery_charging, s_state.usb_powered);
    lv_image_set_src(s_codex_icon, &vibe_stick_provider_codex_icon_40);
    lv_obj_clear_flag(s_codex_icon, LV_OBJ_FLAG_HIDDEN);
    lv_label_set_text(s_codex_label, "Codex");
    lv_obj_set_style_text_color(s_codex_label, lv_color_hex(0xf3f4f6), 0);
    lv_label_set_text(s_status_label, status_text_for(display_state->status));
    lv_label_set_text(s_pet_status_label, status_text_for(display_state->status));
    set_roxy_animation_state(roxy_state_for_status(display_state->status));
    if (strcmp(display_state->status, "RUNNING") == 0 &&
        display_state->active_conversations > 0) {
        char pet_count_text[12];
        snprintf(pet_count_text, sizeof(pet_count_text), "%d", display_state->active_conversations);
        lv_label_set_text(s_pet_active_count_label, pet_count_text);
        lv_obj_clear_flag(s_pet_active_count_label, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(s_pet_active_count_label, LV_OBJ_FLAG_HIDDEN);
    }
    if (strcmp(display_state->status, "RUNNING") == 0 &&
        display_state->active_conversations > 0) {
        const int badge_width = display_state->active_conversations >= 10 ? 22 : 18;
        char count_text[12];
        snprintf(count_text, sizeof(count_text), "%d", display_state->active_conversations);
        lv_obj_set_size(s_status_dot, badge_width, 14);
        lv_obj_set_style_radius(s_status_dot, 7, 0);
        lv_obj_align(s_status_dot, LV_ALIGN_TOP_LEFT, 75 - badge_width, 74);
        lv_obj_set_width(s_active_count_label, badge_width);
        lv_label_set_text(s_active_count_label, count_text);
        lv_obj_clear_flag(s_active_count_label, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_width(s_status_label, 50);
        lv_obj_align(s_status_label, LV_ALIGN_TOP_LEFT, 78, 73);
    } else {
        lv_obj_set_size(s_status_dot, 7, 7);
        lv_obj_set_style_radius(s_status_dot, LV_RADIUS_CIRCLE, 0);
        lv_obj_align(s_status_dot, LV_ALIGN_TOP_LEFT, 65, 80);
        lv_obj_add_flag(s_active_count_label, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_width(s_status_label, 52);
        lv_obj_align(s_status_label, LV_ALIGN_TOP_LEFT, 75, 73);
    }
    set_status_color(display_state->status);
    set_quota_title(s_quota_5h_title_label, "5H", quota_stale);
    set_quota_title(s_quota_7d_title_label, "7D", quota_stale);
    set_quota_label(s_quota_5h_bar, s_quota_5h_label, display_state->quota_5h,
                    q5_valid, s_codex_accent_color);
    set_quota_label(s_quota_7d_bar, s_quota_7d_label, display_state->quota_7d,
                    q7_valid, s_codex_accent_color);
    lv_label_set_text(s_quota_status_label, "");
    lv_obj_add_flag(s_quota_status_label, LV_OBJ_FLAG_HIDDEN);
    lvgl_unlock();
}

static void show_recording_overlay(const char *title, const char *hint, bool visible)
{
    lvgl_lock();
    if (visible) {
        if (title) {
            lv_label_set_text(s_recording_title, title);
        }
        if (hint) {
            lv_label_set_text(s_recording_hint, hint);
            if (hint[0] == '\0') {
                lv_obj_add_flag(s_recording_hint, LV_OBJ_FLAG_HIDDEN);
            } else {
                lv_obj_clear_flag(s_recording_hint, LV_OBJ_FLAG_HIDDEN);
            }
        }
        lv_obj_clear_flag(s_recording_overlay, LV_OBJ_FLAG_HIDDEN);
        start_recording_wave();
    } else {
        stop_recording_wave();
        lv_obj_add_flag(s_recording_overlay, LV_OBJ_FLAG_HIDDEN);
    }
    s_recording_overlay_visible = visible;
    lvgl_unlock();
}

static bool sound_for_alert_type(const char *type, agent_sound_t *sound)
{
    if (strcmp(type, "DONE") == 0 ||
        strcmp(type, "COMPLETED") == 0 ||
        strcmp(type, "SUCCESS") == 0) {
        *sound = VIBE_STICK_SOUND_DONE;
        return true;
    }
    if (strcmp(type, "ERROR") == 0 ||
        strcmp(type, "FAILED") == 0 ||
        strcmp(type, "FAILURE") == 0) {
        *sound = VIBE_STICK_SOUND_ERROR;
        return true;
    }
    if (strcmp(type, "APPROVAL") == 0 ||
        strcmp(type, "WAITING_APPROVAL") == 0 ||
        strcmp(type, "PENDING_APPROVAL") == 0 ||
        strcmp(type, "NEEDS_APPROVAL") == 0) {
        *sound = VIBE_STICK_SOUND_APPROVAL;
        return true;
    }
    return false;
}

static void remember_alert_sound_baseline(const char *event_id, const char *type)
{
    strlcpy(s_last_alert_event_id, event_id, sizeof(s_last_alert_event_id));
    strlcpy(s_last_alert_type, type, sizeof(s_last_alert_type));
    s_alert_sound_baseline_ready = true;
}

static bool alert_sound_matches_baseline(const char *event_id, const char *type)
{
    if (!s_alert_sound_baseline_ready) {
        return false;
    }
    if (event_id[0] != '\0') {
        return strcmp(s_last_alert_event_id, event_id) == 0;
    }
    return strcmp(s_last_alert_type, type) == 0;
}

static bool pending_alert_sound_matches(const pending_alert_sound_t *pending,
                                        const char *event_id, const char *type)
{
    if (event_id[0] != '\0') {
        return strcmp(pending->event_id, event_id) == 0;
    }
    return pending->event_id[0] == '\0' && strcmp(pending->type, type) == 0;
}

static bool pending_alert_sound_contains(const char *event_id, const char *type)
{
    for (size_t i = 0; i < s_pending_alert_sound_count; ++i) {
        size_t index = (s_pending_alert_sound_head + i) % ALERT_SOUND_PENDING_CAPACITY;
        if (pending_alert_sound_matches(&s_pending_alert_sounds[index], event_id, type)) {
            return true;
        }
    }
    return false;
}

static bool queue_pending_alert_sound(const char *event_id, const char *type)
{
    if (alert_sound_matches_baseline(event_id, type) ||
        pending_alert_sound_contains(event_id, type)) {
        return true;
    }
    if (s_pending_alert_sound_count >= ALERT_SOUND_PENDING_CAPACITY) {
        ESP_LOGW(TAG, "pending alert sound queue full event_id=%s type=%s", event_id, type);
        return false;
    }
    size_t tail = (s_pending_alert_sound_head + s_pending_alert_sound_count) %
                  ALERT_SOUND_PENDING_CAPACITY;
    strlcpy(s_pending_alert_sounds[tail].event_id, event_id,
            sizeof(s_pending_alert_sounds[tail].event_id));
    strlcpy(s_pending_alert_sounds[tail].type, type,
            sizeof(s_pending_alert_sounds[tail].type));
    s_pending_alert_sound_count++;
    ESP_LOGI(TAG, "deferred alert sound event_id=%s type=%s pending=%u",
             event_id, type, (unsigned)s_pending_alert_sound_count);
    return true;
}

static void play_pending_alert_sounds(void)
{
    if (s_pending_alert_sound_count > 0 &&
        !s_recording_overlay_visible && !vibe_audio_is_recording()) {
        pending_alert_sound_t *pending = &s_pending_alert_sounds[s_pending_alert_sound_head];
        agent_sound_t sound;
        if (!sound_for_alert_type(pending->type, &sound)) {
            ESP_LOGW(TAG, "discard invalid pending alert sound type=%s", pending->type);
        } else {
            esp_err_t err = vibe_audio_play_sound(sound);
            if (err != ESP_OK) {
                ESP_LOGW(TAG, "pending alert sound retained type=%s err=%s",
                         pending->type, esp_err_to_name(err));
                return;
            }
            remember_alert_sound_baseline(pending->event_id, pending->type);
            ESP_LOGI(TAG, "played deferred alert event_id=%s type=%s",
                     pending->event_id, pending->type);
        }
        s_pending_alert_sound_head =
            (s_pending_alert_sound_head + 1) % ALERT_SOUND_PENDING_CAPACITY;
        s_pending_alert_sound_count--;
    }
}

static void maybe_handle_alert(void)
{
    if (!s_recording_overlay_visible && !vibe_audio_is_recording()) {
        play_pending_alert_sounds();
    }

    agent_sound_t sound;
    if (!sound_for_alert_type(s_state.alert_type, &sound)) {
        if (!s_alert_sound_baseline_ready) {
            remember_alert_sound_baseline(s_state.alert_event_id, s_state.alert_type);
        }
        return;
    }
    if (!s_alert_sound_baseline_ready) {
        remember_alert_sound_baseline(s_state.alert_event_id, s_state.alert_type);
        return;
    }
    if (alert_sound_matches_baseline(s_state.alert_event_id, s_state.alert_type) ||
        pending_alert_sound_contains(s_state.alert_event_id, s_state.alert_type)) {
        return;
    }
    if (s_recording_overlay_visible || vibe_audio_is_recording()) {
        (void)queue_pending_alert_sound(s_state.alert_event_id, s_state.alert_type);
        return;
    }

    esp_err_t err = vibe_audio_play_sound(sound);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "alert sound retained for retry type=%s err=%s",
                 s_state.alert_type, esp_err_to_name(err));
        (void)queue_pending_alert_sound(s_state.alert_event_id, s_state.alert_type);
        return;
    }
    remember_alert_sound_baseline(s_state.alert_event_id, s_state.alert_type);
    ESP_LOGI(TAG, "alert type=%s message=%s",
             s_state.alert_type, s_state.alert_message);
}

static void finish_recording_overlay(void)
{
    show_recording_overlay(NULL, NULL, false);
    play_pending_alert_sounds();
}

static void open_post_recording_action_window(void)
{
    s_post_recording_action_deadline_ms =
        (esp_timer_get_time() / 1000) + POST_RECORDING_ACTION_WINDOW_MS;
    ESP_LOGI(TAG, "single/double click enabled for %d ms after recording",
             POST_RECORDING_ACTION_WINDOW_MS);
}

static void close_post_recording_action_window(void)
{
    s_post_recording_action_deadline_ms = 0;
}

static bool post_recording_action_available(void)
{
    if (s_post_recording_action_deadline_ms <= 0) {
        return false;
    }
    if ((esp_timer_get_time() / 1000) > s_post_recording_action_deadline_ms) {
        close_post_recording_action_window();
        return false;
    }
    return true;
}

static esp_err_t http_event_handler(esp_http_client_event_t *evt)
{
    if (evt->event_id != HTTP_EVENT_ON_DATA || !evt->user_data || !evt->data || evt->data_len <= 0) {
        return ESP_OK;
    }

    http_response_capture_t *capture = (http_response_capture_t *)evt->user_data;
    if (!capture->data || capture->capacity <= 0 || capture->used >= capture->capacity - 1) {
        capture->truncated = true;
        return ESP_OK;
    }

    int remaining = capture->capacity - 1 - capture->used;
    int copy_len = evt->data_len < remaining ? evt->data_len : remaining;
    memcpy(capture->data + capture->used, evt->data, copy_len);
    capture->used += copy_len;
    capture->data[capture->used] = '\0';
    if (copy_len < evt->data_len) {
        capture->truncated = true;
    }
    return ESP_OK;
}

static esp_err_t validate_http_result(esp_err_t perform_err, int status_code,
                                      const http_response_capture_t *capture,
                                      const char *method, const char *path)
{
    if (perform_err != ESP_OK) {
        ESP_LOGW(TAG, "http %s %s failed: %s", method, path, esp_err_to_name(perform_err));
        return perform_err;
    }
    if (status_code < 200 || status_code >= 300) {
        ESP_LOGW(TAG, "http %s %s rejected status=%d", method, path, status_code);
        return ESP_ERR_INVALID_RESPONSE;
    }
    if (capture->truncated) {
        ESP_LOGW(TAG, "http %s %s response truncated at %d bytes",
                 method, path, capture->used);
        return ESP_ERR_INVALID_SIZE;
    }
    if (capture->data && capture->capacity > 0 && capture->used == 0) {
        ESP_LOGW(TAG, "http %s %s status=%d empty response", method, path, status_code);
        return ESP_ERR_INVALID_RESPONSE;
    }
    return ESP_OK;
}

static esp_err_t http_request_timeout(const char *method, const char *path, const char *body,
                                      char *response, int response_len, int timeout_ms)
{
    char url[160];
    snprintf(url, sizeof(url), "http://%s:%d%s", VIBE_STICK_BRIDGE_HOST, VIBE_STICK_BRIDGE_PORT, path);
    http_response_capture_t capture = {
        .data = response,
        .capacity = response_len,
        .used = 0,
        .truncated = false,
    };
    if (response && response_len > 0) {
        response[0] = '\0';
    }
    esp_http_client_config_t config = {
        .url = url,
        .timeout_ms = timeout_ms,
        .event_handler = http_event_handler,
        .user_data = &capture,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    ESP_RETURN_ON_FALSE(client != NULL, ESP_ERR_NO_MEM, TAG, "http init");
    esp_http_client_set_method(client, strcmp(method, "POST") == 0 ? HTTP_METHOD_POST : HTTP_METHOD_GET);
    esp_http_client_set_header(client, "X-Vibe-Stick-Firmware-Name", FIRMWARE_NAME);
    esp_http_client_set_header(client, "X-Vibe-Stick-Firmware-Version", FIRMWARE_VERSION);
    esp_http_client_set_header(client, "X-Vibe-Stick-Firmware-Transport", TRANSPORT);
    esp_http_client_set_header(client, "X-Vibe-Stick-Firmware-Build-Date", __DATE__ " " __TIME__);
    esp_http_client_set_header(client, "X-Vibe-Stick-Deployment-Nonce", VIBE_STICK_DEPLOYMENT_NONCE);
    if (strlen(VIBE_STICK_BRIDGE_TOKEN) > 0) {
        esp_http_client_set_header(client, "X-Vibe-Stick-Token", VIBE_STICK_BRIDGE_TOKEN);
    }
    if (body) {
        esp_http_client_set_header(client, "Content-Type", "application/json");
        esp_http_client_set_post_field(client, body, strlen(body));
    }
    esp_err_t err = esp_http_client_perform(client);
    int status_code = esp_http_client_get_status_code(client);
    err = validate_http_result(err, status_code, &capture, method, path);
    esp_http_client_cleanup(client);
    return err;
}

static esp_err_t http_request(const char *method, const char *path, const char *body,
                              char *response, int response_len)
{
    return http_request_timeout(method, path, body, response, response_len, 2500);
}

static esp_err_t http_post_binary(const char *path, const uint8_t *body, size_t body_len,
                                  char *response, int response_len)
{
    char url[192];
    snprintf(url, sizeof(url), "http://%s:%d%s", VIBE_STICK_BRIDGE_HOST, VIBE_STICK_BRIDGE_PORT, path);
    http_response_capture_t capture = {
        .data = response,
        .capacity = response_len,
        .used = 0,
        .truncated = false,
    };
    if (response && response_len > 0) {
        response[0] = '\0';
    }
    esp_http_client_config_t config = {
        .url = url,
        .timeout_ms = 20000,
        .event_handler = http_event_handler,
        .user_data = &capture,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    ESP_RETURN_ON_FALSE(client != NULL, ESP_ERR_NO_MEM, TAG, "http init");
    esp_http_client_set_method(client, HTTP_METHOD_POST);
    esp_http_client_set_header(client, "X-Vibe-Stick-Firmware-Name", FIRMWARE_NAME);
    esp_http_client_set_header(client, "X-Vibe-Stick-Firmware-Version", FIRMWARE_VERSION);
    esp_http_client_set_header(client, "X-Vibe-Stick-Firmware-Transport", TRANSPORT);
    esp_http_client_set_header(client, "X-Vibe-Stick-Firmware-Build-Date", __DATE__ " " __TIME__);
    esp_http_client_set_header(client, "X-Vibe-Stick-Deployment-Nonce", VIBE_STICK_DEPLOYMENT_NONCE);
    if (strlen(VIBE_STICK_BRIDGE_TOKEN) > 0) {
        esp_http_client_set_header(client, "X-Vibe-Stick-Token", VIBE_STICK_BRIDGE_TOKEN);
    }
    esp_http_client_set_header(client, "Content-Type", "application/octet-stream");
    esp_http_client_set_header(client, "X-Vibe-Stick-Sample-Rate", "16000");
    esp_http_client_set_header(client, "X-Vibe-Stick-Channels", "1");
    esp_http_client_set_header(client, "X-Vibe-Stick-Bits-Per-Sample", "16");
    esp_http_client_set_post_field(client, (const char *)body, body_len);
    esp_err_t err = esp_http_client_perform(client);
    int status_code = esp_http_client_get_status_code(client);
    err = validate_http_result(err, status_code, &capture, "POST", path);
    esp_http_client_cleanup(client);
    return err;
}

static void copy_json_string(cJSON *root, const char *key, char *target, size_t target_len)
{
    cJSON *item = cJSON_GetObjectItemCaseSensitive(root, key);
    if (cJSON_IsString(item) && item->valuestring) {
        strlcpy(target, item->valuestring, target_len);
    }
}

static bool json_percent_value(cJSON *item, int *value)
{
    if (cJSON_IsNumber(item)) {
        *value = item->valueint;
    } else if (cJSON_IsString(item) && item->valuestring && item->valuestring[0] != '\0') {
        char *end = NULL;
        long parsed = strtol(item->valuestring, &end, 10);
        if (!end || end == item->valuestring) {
            return false;
        }
        while (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n' || *end == '%') {
            end++;
        }
        if (*end != '\0') {
            return false;
        }
        *value = (int)parsed;
    } else {
        return false;
    }
    if (*value < 0) {
        *value = 0;
    } else if (*value > 100) {
        *value = 100;
    }
    return true;
}

static void parse_codex_fields(cJSON *source, codex_display_state_t *target)
{
    copy_json_string(source, "status", target->status, sizeof(target->status));
    copy_json_string(source, "project", target->project, sizeof(target->project));
    copy_json_string(source, "quota_updated_at", target->quota_updated_at, sizeof(target->quota_updated_at));

    cJSON *active_conversations = cJSON_GetObjectItemCaseSensitive(source, "active_conversations");
    cJSON *quota_5h = cJSON_GetObjectItemCaseSensitive(source, "quota_5h_remaining");
    cJSON *quota_7d = cJSON_GetObjectItemCaseSensitive(source, "quota_7d_remaining");
    cJSON *stale = cJSON_GetObjectItemCaseSensitive(source, "quota_stale");
    int quota_value = 0;
    target->active_conversations = cJSON_IsNumber(active_conversations)
                                       ? active_conversations->valueint
                                       : 0;
    if (target->active_conversations < 0) {
        target->active_conversations = 0;
    } else if (target->active_conversations > 99) {
        target->active_conversations = 99;
    }
    target->quota_5h_valid = json_percent_value(quota_5h, &quota_value);
    if (target->quota_5h_valid) {
        target->quota_5h = quota_value;
    }
    target->quota_7d_valid = json_percent_value(quota_7d, &quota_value);
    if (target->quota_7d_valid) {
        target->quota_7d = quota_value;
    }
    target->quota_stale = cJSON_IsBool(stale) ? cJSON_IsTrue(stale) : false;
}

static void parse_codex_json(cJSON *codex)
{
    codex_display_state_t *display_state = &s_codex_state;
    parse_codex_fields(codex, display_state);
    ESP_LOGI(TAG, "codex parsed status=%s active=%d q5=%s%d q7=%s%d stale=%d",
             display_state->status,
             display_state->active_conversations,
             display_state->quota_5h_valid ? "" : "invalid:",
             display_state->quota_5h,
             display_state->quota_7d_valid ? "" : "invalid:",
             display_state->quota_7d,
             display_state->quota_stale);
}

static bool json_has_nonempty_string(cJSON *object, const char *key)
{
    cJSON *item = cJSON_GetObjectItemCaseSensitive(object, key);
    return cJSON_IsString(item) && item->valuestring && item->valuestring[0] != '\0';
}

static bool state_json_has_core_fields(cJSON *state_root)
{
    if (!cJSON_IsObject(state_root)) {
        return false;
    }
    cJSON *codex = cJSON_GetObjectItemCaseSensitive(state_root, "codex");
    return cJSON_IsObject(codex) &&
           json_has_nonempty_string(codex, "status") &&
           json_has_nonempty_string(codex, "project");
}

static bool parse_state_json(const char *json)
{
    cJSON *root = cJSON_Parse(json);
    if (!root) {
        return false;
    }
    cJSON *state_root = root;
    cJSON *wrapped_state = cJSON_GetObjectItemCaseSensitive(root, "state");
    if (cJSON_IsObject(wrapped_state)) {
        state_root = wrapped_state;
    }
    if (!state_json_has_core_fields(state_root)) {
        ESP_LOGW(TAG, "state response missing required codex fields");
        cJSON_Delete(root);
        return false;
    }

    copy_json_string(state_root, "time", s_state.time, sizeof(s_state.time));
    cJSON *wifi = cJSON_GetObjectItemCaseSensitive(state_root, "wifi");
    cJSON *ble = cJSON_GetObjectItemCaseSensitive(state_root, "ble");
    s_state.wifi = cJSON_IsBool(wifi) ? cJSON_IsTrue(wifi) : s_state.wifi;
    s_state.ble = cJSON_IsBool(ble) ? cJSON_IsTrue(ble) : s_state.ble;

    cJSON *codex = cJSON_GetObjectItemCaseSensitive(state_root, "codex");
    parse_codex_json(codex);

    cJSON *alert = cJSON_GetObjectItemCaseSensitive(state_root, "alert");
    if (cJSON_IsObject(alert)) {
        copy_json_string(alert, "event_id", s_state.alert_event_id, sizeof(s_state.alert_event_id));
        copy_json_string(alert, "type", s_state.alert_type, sizeof(s_state.alert_type));
        copy_json_string(alert, "message", s_state.alert_message, sizeof(s_state.alert_message));
    }
    cJSON_Delete(root);
    return true;
}

static bool refresh_power_state(void)
{
    const int previous_battery = s_state.battery;
    const bool previous_battery_valid = s_state.battery_valid;
    const bool previous_charging = s_state.battery_charging;
    const bool previous_usb_powered = s_state.usb_powered;
    int battery_level = 0;
    if (vibe_board_battery_level(&battery_level) == ESP_OK) {
        s_state.battery = battery_level;
        s_state.battery_valid = true;
    }
    bool charging = false;
    bool usb_powered = false;
    bool power_read_ok = false;
    if (vibe_board_battery_charging(&charging) == ESP_OK) {
        s_state.battery_charging = charging;
        power_read_ok = true;
    }
    if (vibe_board_usb_powered(&usb_powered) == ESP_OK) {
        s_state.usb_powered = usb_powered;
        power_read_ok = true;
    }
    static bool last_power_logged = false;
    static bool last_charging = false;
    static bool last_usb_powered = false;
    if (power_read_ok &&
        (!last_power_logged ||
         last_charging != s_state.battery_charging ||
         last_usb_powered != s_state.usb_powered)) {
        ESP_LOGI(TAG, "power status battery=%d charging=%d usb=%d",
                 s_state.battery, s_state.battery_charging, s_state.usb_powered);
        last_power_logged = true;
        last_charging = s_state.battery_charging;
        last_usb_powered = s_state.usb_powered;
    }
    return previous_battery != s_state.battery ||
           previous_battery_valid != s_state.battery_valid ||
           previous_charging != s_state.battery_charging ||
           previous_usb_powered != s_state.usb_powered;
}

static void poll_state(void)
{
    char response[HTTP_JSON_RESPONSE_CAPACITY] = {0};
    esp_err_t err = http_request("GET", VIBE_STICK_STATE_PATH, NULL, response, sizeof(response));
    if (err != ESP_OK || response[0] == '\0' || !parse_state_json(response)) {
        strlcpy(s_codex_state.status, "OFFLINE", sizeof(s_codex_state.status));
        s_state.wifi = s_wifi_connected;
        render_state();
        return;
    }
    render_state();
    maybe_handle_alert();
}

static void post_simple_event(const char *event_name, const char *path)
{
    char body[96];
    snprintf(body, sizeof(body), "{\"event\":\"%s\",\"source\":\"sticks3\"}", event_name);
    char response[HTTP_JSON_RESPONSE_CAPACITY] = {0};
    const char *target_path = path ? path : VIBE_STICK_EVENT_PATH;
    esp_err_t err = http_request("POST", target_path, body, response, sizeof(response));
    if (err == ESP_OK && response[0] != '\0' && parse_state_json(response)) {
        render_state();
        maybe_handle_alert();
    }
}

static bool parse_recording_session_id(const char *json, char *session_id, size_t session_id_len)
{
    cJSON *root = cJSON_Parse(json);
    if (!root) {
        return false;
    }
    cJSON *recording = cJSON_GetObjectItemCaseSensitive(root, "recording");
    cJSON *sid = cJSON_IsObject(recording) ? cJSON_GetObjectItemCaseSensitive(recording, "session_id") : NULL;
    bool ok = false;
    if (cJSON_IsString(sid) && sid->valuestring && sid->valuestring[0] != '\0') {
        strlcpy(session_id, sid->valuestring, session_id_len);
        ok = true;
    }
    cJSON_Delete(root);
    return ok;
}

static bool is_recording_failure_status(const char *status)
{
    return strcmp(status, "transcription_failed") == 0 ||
           strcmp(status, "transcript_rejected") == 0 ||
           strcmp(status, "paste_failed") == 0 ||
           strcmp(status, "audio_failed") == 0 ||
           strcmp(status, "audio_skipped") == 0 ||
           strcmp(status, "start_failed") == 0 ||
           strcmp(status, "stop_failed") == 0;
}

static bool is_recording_success_status(const char *status)
{
    return strcmp(status, "pasted") == 0 ||
           strcmp(status, "transcribed") == 0;
}

static bool is_recording_terminal_status(const char *status)
{
    return is_recording_success_status(status) ||
           is_recording_failure_status(status);
}

static bool is_recording_known_status(const char *status)
{
    return strcmp(status, "recording") == 0 ||
           is_recording_terminal_status(status);
}

static bool parse_recording_status(const char *json, char *status_text, size_t status_text_len)
{
    if (status_text_len > 0) {
        status_text[0] = '\0';
    }
    cJSON *root = cJSON_Parse(json);
    if (!root) {
        return false;
    }
    cJSON *recording = cJSON_GetObjectItemCaseSensitive(root, "recording");
    cJSON *status = cJSON_IsObject(recording) ?
        cJSON_GetObjectItemCaseSensitive(recording, "status") : NULL;
    bool ok = false;
    if (cJSON_IsString(status) && status->valuestring && status->valuestring[0] != '\0') {
        strlcpy(status_text, status->valuestring, status_text_len);
        ok = true;
    }
    cJSON_Delete(root);
    return ok;
}

static void generate_recording_session_id(char *session_id, size_t session_id_len)
{
    if (session_id_len < 33) {
        if (session_id_len > 0) {
            session_id[0] = '\0';
        }
        return;
    }
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 32; ++i) {
        uint32_t value = esp_random();
        session_id[i] = hex[value & 0x0f];
    }
    session_id[32] = '\0';
}

static esp_err_t upload_recording_audio(bool *terminal_rejection)
{
    if (terminal_rejection) {
        *terminal_rejection = false;
    }
    size_t audio_len = 0;
    const uint8_t *audio = vibe_audio_data(&audio_len);
    if (!audio || audio_len == 0 || s_recording_session_id[0] == '\0') {
        ESP_LOGW(TAG, "skip audio upload audio=%p len=%u session=%s",
                 audio, (unsigned)audio_len, s_recording_session_id);
        return ESP_ERR_INVALID_STATE;
    }
    char path[96];
    snprintf(path, sizeof(path), "%s?session_id=%s", VIBE_STICK_RECORDING_AUDIO_PATH, s_recording_session_id);
    char response[HTTP_JSON_RESPONSE_CAPACITY] = {0};
    esp_err_t err = http_post_binary(path, audio, audio_len, response, sizeof(response));
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "audio upload failed: %s", esp_err_to_name(err));
        return err;
    }
    char recording_status[32] = {0};
    if (!parse_recording_status(response, recording_status, sizeof(recording_status))) {
        ESP_LOGW(TAG, "audio upload returned no recording status");
        return ESP_ERR_INVALID_RESPONSE;
    }
    char response_session_id[40] = {0};
    if (!parse_recording_session_id(response, response_session_id,
                                    sizeof(response_session_id)) ||
        strcmp(response_session_id, s_recording_session_id) != 0) {
        ESP_LOGW(TAG, "audio upload returned a different recording session id");
        return ESP_ERR_INVALID_RESPONSE;
    }
    if (!is_recording_known_status(recording_status)) {
        ESP_LOGW(TAG, "audio upload returned unknown status=%s", recording_status);
        return ESP_ERR_INVALID_RESPONSE;
    }
    if (is_recording_failure_status(recording_status)) {
        ESP_LOGW(TAG, "audio upload reached terminal status=%s", recording_status);
        if (terminal_rejection) {
            *terminal_rejection = true;
        }
        return ESP_FAIL;
    }
    if (parse_state_json(response)) {
        render_state();
        maybe_handle_alert();
    }
    return ESP_OK;
}

static void handle_recording_start(void)
{
    if (s_recording_session_id[0] != '\0') {
        /*
         * A previous upload or stop request failed after capture completed.
         * Preserve that session and make the next long press a reachable retry
         * instead of allowing vibe_audio_start() to clear its PCM buffer.
         */
        ESP_LOGI(TAG, "retry retained recording session=%s uploaded=%d",
                 s_recording_session_id, s_recording_audio_uploaded);
        atomic_store(&s_long_press_active, false);
        handle_recording_stop();
        return;
    }

    close_post_recording_action_window();
    generate_recording_session_id(s_recording_session_id, sizeof(s_recording_session_id));
    s_recording_audio_uploaded = false;
    if (s_recording_session_id[0] == '\0') {
        ESP_LOGW(TAG, "recording start failed: no session id");
        return;
    }

    esp_err_t audio_err = vibe_audio_start();
    if (audio_err != ESP_OK) {
        ESP_LOGW(TAG, "hardware recording start failed: %s", esp_err_to_name(audio_err));
        s_recording_session_id[0] = '\0';
        s_recording_audio_uploaded = false;
        return;
    }
    show_recording_overlay("正在聆听", "松开识别", true);

    char body[192];
    snprintf(body, sizeof(body),
             "{\"event\":\"button_long_start\",\"source\":\"sticks3\","
             "\"audio_source\":\"sticks3_pcm\",\"session_id\":\"%s\"}",
             s_recording_session_id);
    char response[HTTP_JSON_RESPONSE_CAPACITY] = {0};
    esp_err_t err = http_request("POST", VIBE_STICK_RECORDING_START_PATH, body, response, sizeof(response));
    if (err == ESP_OK && response[0] != '\0') {
        char response_session_id[40] = {0};
        char recording_status[32] = {0};
        bool has_session_id = parse_recording_session_id(
            response, response_session_id, sizeof(response_session_id));
        bool has_status = parse_recording_status(
            response, recording_status, sizeof(recording_status));
        bool same_session = has_session_id &&
            strcmp(response_session_id, s_recording_session_id) == 0;
        if (same_session && has_status && is_recording_terminal_status(recording_status)) {
            ESP_LOGW(TAG, "bridge rejected recording start status=%s",
                     recording_status);
            esp_err_t stop_err = vibe_audio_stop();
            if (stop_err == ESP_OK) {
                vibe_audio_clear();
            } else {
                ESP_LOGW(TAG, "hardware stop after rejected start failed: %s",
                         esp_err_to_name(stop_err));
            }
            s_recording_session_id[0] = '\0';
            s_recording_audio_uploaded = false;
            show_recording_overlay("录音失败", "", true);
            vTaskDelay(pdMS_TO_TICKS(900));
            poll_state();
            finish_recording_overlay();
            return;
        }
        if (!same_session || !has_status || strcmp(recording_status, "recording") != 0) {
            /* Keep capturing. The audio upload can reconstruct the session
             * when an otherwise successful response was malformed in transit. */
            ESP_LOGW(TAG, "recording start response incomplete session=%s status=%s",
                     response_session_id, recording_status);
        }
        if (parse_state_json(response)) {
            render_state();
            maybe_handle_alert();
        }
    } else {
        ESP_LOGW(TAG, "recording start bridge request failed: %s", esp_err_to_name(err));
    }

}

static void handle_recording_stop(void)
{
    bool enable_post_recording_actions = false;
    show_recording_overlay("正在发送", "", true);
    if (s_recording_session_id[0] == '\0') {
        esp_err_t stop_err = vibe_audio_stop();
        if (stop_err == ESP_OK) {
            vibe_audio_clear();
        } else {
            ESP_LOGW(TAG, "hardware recording stop without session failed: %s",
                     esp_err_to_name(stop_err));
        }
        s_recording_audio_uploaded = false;
        poll_state();
        finish_recording_overlay();
        return;
    }

    esp_err_t audio_err = vibe_audio_stop();
    if (audio_err != ESP_OK) {
        ESP_LOGW(TAG, "hardware recording stop failed: %s", esp_err_to_name(audio_err));
        show_recording_overlay("录音失败", "", true);
        vTaskDelay(pdMS_TO_TICKS(900));
        poll_state();
        finish_recording_overlay();
        return;
    }

    if (!s_recording_audio_uploaded) {
        bool terminal_rejection = false;
        esp_err_t upload_err = upload_recording_audio(&terminal_rejection);
        if (upload_err != ESP_OK) {
            if (terminal_rejection) {
                ESP_LOGW(TAG, "discarding recording rejected by terminal bridge session");
                vibe_audio_clear();
                s_recording_session_id[0] = '\0';
                s_recording_audio_uploaded = false;
                show_recording_overlay("识别失败", "", true);
                vTaskDelay(pdMS_TO_TICKS(900));
                poll_state();
                finish_recording_overlay();
                return;
            }
            ESP_LOGW(TAG, "recording audio retained for retry: %s", esp_err_to_name(upload_err));
            show_recording_overlay("发送失败", "", true);
            vTaskDelay(pdMS_TO_TICKS(900));
            poll_state();
            finish_recording_overlay();
            return;
        }
        s_recording_audio_uploaded = true;
        vibe_audio_clear();
    }

    show_recording_overlay("正在识别", "", true);
    char body[192];
    snprintf(body, sizeof(body),
             "{\"event\":\"button_long_stop\",\"source\":\"sticks3\","
             "\"paste\":true,\"session_id\":\"%s\"}",
             s_recording_session_id);
    char response[3072] = {0};
    esp_err_t err = http_request_timeout("POST", VIBE_STICK_RECORDING_STOP_PATH, body, response, sizeof(response), 30000);
    bool recording_failed = false;
    bool stop_response_valid = false;
    char recording_status[32] = {0};
    if (err == ESP_OK) {
        stop_response_valid = parse_recording_status(response, recording_status,
                                                     sizeof(recording_status));
        char response_session_id[40] = {0};
        stop_response_valid = stop_response_valid &&
            parse_recording_session_id(response, response_session_id,
                                       sizeof(response_session_id)) &&
            strcmp(response_session_id, s_recording_session_id) == 0 &&
            is_recording_terminal_status(recording_status);
        if (stop_response_valid) {
            recording_failed = is_recording_failure_status(recording_status);
            if (recording_failed) {
                ESP_LOGW(TAG, "recording failed status=%s", recording_status);
            }
        } else {
            err = ESP_ERR_INVALID_RESPONSE;
        }
        if (parse_state_json(response)) {
            render_state();
            maybe_handle_alert();
        }
    }
    if (err != ESP_OK || recording_failed) {
        ESP_LOGW(TAG, "recording stop bridge request failed: %s", esp_err_to_name(err));
        const char *title = (strcmp(recording_status, "audio_skipped") == 0 ||
                             strcmp(recording_status, "transcript_rejected") == 0)
            ? "未听清" : "识别失败";
        show_recording_overlay(title, "", true);
        vTaskDelay(pdMS_TO_TICKS(900));
    }
    if (err == ESP_OK && stop_response_valid) {
        enable_post_recording_actions =
            is_recording_success_status(recording_status);
        s_recording_session_id[0] = '\0';
        s_recording_audio_uploaded = false;
    } else {
        ESP_LOGW(TAG, "recording session retained for stop retry session=%s",
                 s_recording_session_id);
    }
    poll_state();
    finish_recording_overlay();
    if (enable_post_recording_actions) {
        open_post_recording_action_window();
    }
}

static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data)
{
    (void)arg;
    (void)event_data;
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        s_wifi_connected = false;
        esp_wifi_connect();
        render_state();
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        s_wifi_connected = true;
        render_state();
        queue_event(VIBE_STICK_EVENT_POLL_STATE);
    }
}

static esp_err_t init_wifi(void)
{
    if (strlen(VIBE_STICK_WIFI_SSID) == 0) {
        ESP_LOGW(TAG, "VIBE_STICK_WIFI_SSID is empty; Wi-Fi disabled");
        return ESP_OK;
    }
    ESP_RETURN_ON_ERROR(esp_netif_init(), TAG, "netif init");
    ESP_RETURN_ON_ERROR(esp_event_loop_create_default(), TAG, "event loop");
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&cfg), TAG, "wifi init");
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL));
    wifi_config_t wifi_config = {0};
    strlcpy((char *)wifi_config.sta.ssid, VIBE_STICK_WIFI_SSID, sizeof(wifi_config.sta.ssid));
    strlcpy((char *)wifi_config.sta.password, VIBE_STICK_WIFI_PASSWORD, sizeof(wifi_config.sta.password));
    wifi_config.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_STA), TAG, "wifi mode");
    ESP_RETURN_ON_ERROR(esp_wifi_set_config(WIFI_IF_STA, &wifi_config), TAG, "wifi config");
    ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "wifi start");
    return ESP_OK;
}

static void button_single_click_cb(void *button_handle, void *usr_data)
{
    (void)button_handle;
    (void)usr_data;
    queue_event(VIBE_STICK_EVENT_SHORT_PRESS);
}

static void button_double_click_cb(void *button_handle, void *usr_data)
{
    (void)button_handle;
    (void)usr_data;
    queue_event(VIBE_STICK_EVENT_DOUBLE_CLICK);
}

static void button_side_click_cb(void *button_handle, void *usr_data)
{
    (void)button_handle;
    (void)usr_data;
    queue_event(VIBE_STICK_EVENT_TOGGLE_VIEW);
}

static void button_long_start_cb(void *button_handle, void *usr_data)
{
    (void)button_handle;
    (void)usr_data;
    atomic_store(&s_long_press_active, true);
    atomic_store(&s_long_start_pending, true);
    queue_event(VIBE_STICK_EVENT_LONG_START);
}

static void button_up_cb(void *button_handle, void *usr_data)
{
    (void)button_handle;
    (void)usr_data;
    if (atomic_exchange(&s_long_press_active, false)) {
        atomic_store(&s_long_stop_pending, true);
        queue_event(VIBE_STICK_EVENT_LONG_STOP);
    }
}

static esp_err_t init_buttons(void)
{
    button_handle_t front_button = NULL;
    const button_config_t button_config = {0};
    const button_gpio_config_t front_gpio_config = {
        .gpio_num = PIN_BUTTON_FRONT,
        .active_level = 0,
        .enable_power_save = true,
    };
    ESP_RETURN_ON_ERROR(iot_button_new_gpio_device(&button_config, &front_gpio_config,
                                                    &front_button),
                        TAG, "front button");
    ESP_RETURN_ON_ERROR(iot_button_register_cb(front_button, BUTTON_SINGLE_CLICK, NULL,
                                                button_single_click_cb, NULL),
                        TAG, "front button single");
    ESP_RETURN_ON_ERROR(iot_button_register_cb(front_button, BUTTON_DOUBLE_CLICK, NULL,
                                                button_double_click_cb, NULL),
                        TAG, "front button double");
    button_event_args_t long_press_args = {
        .long_press = {
            .press_time = 450,
        },
    };
    ESP_RETURN_ON_ERROR(iot_button_register_cb(front_button, BUTTON_LONG_PRESS_START,
                                                &long_press_args, button_long_start_cb, NULL),
                        TAG, "front button long");
    ESP_RETURN_ON_ERROR(iot_button_register_cb(front_button, BUTTON_PRESS_UP, NULL,
                                                button_up_cb, NULL),
                        TAG, "front button up");

    button_handle_t side_button = NULL;
    const button_gpio_config_t side_gpio_config = {
        .gpio_num = PIN_BUTTON_SIDE,
        .active_level = 0,
        .enable_power_save = true,
    };
    ESP_RETURN_ON_ERROR(iot_button_new_gpio_device(&button_config, &side_gpio_config,
                                                    &side_button),
                        TAG, "side button");
    ESP_RETURN_ON_ERROR(iot_button_register_cb(side_button, BUTTON_SINGLE_CLICK, NULL,
                                                button_side_click_cb, NULL),
                        TAG, "side button single");
    return ESP_OK;
}

static bool process_pending_long_start(void)
{
    if (!atomic_exchange(&s_long_start_pending, false)) {
        return false;
    }
    if (atomic_exchange(&s_long_stop_pending, false)) {
        atomic_store(&s_long_press_active, false);
        if (vibe_audio_is_recording() || s_recording_session_id[0] != '\0') {
            /* Preserve a stop already owed by an active or retained session. */
            handle_recording_stop();
            return true;
        }
        /* The whole press/release happened while the app task was busy. */
        ESP_LOGW(TAG, "discard stale long press completed before recording could start");
        return true;
    }
    handle_recording_start();
    return true;
}

static void app_task(void *arg)
{
    (void)arg;
    agent_event_t event;
    int64_t last_poll = 0;
    int64_t last_power_poll = 0;
    while (true) {
        if (process_pending_long_start()) {
            continue;
        }
        if (atomic_exchange(&s_long_stop_pending, false)) {
            handle_recording_stop();
            continue;
        }
        int64_t now_ms = esp_timer_get_time() / 1000;
        if (now_ms - last_power_poll >= POWER_STATE_POLL_MS) {
            last_power_poll = now_ms;
            if (refresh_power_state()) {
                render_state();
            }
        }
        if (s_wifi_connected && now_ms - last_poll >= VIBE_STICK_STATE_POLL_MS) {
            last_poll = now_ms;
            poll_state();
        }
        if (xQueueReceive(s_event_queue, &event, pdMS_TO_TICKS(100)) != pdTRUE) {
            continue;
        }
        switch (event.type) {
        case VIBE_STICK_EVENT_POLL_STATE:
            poll_state();
            break;
        case VIBE_STICK_EVENT_SHORT_PRESS:
            if (post_recording_action_available()) {
                post_simple_event("button_short", NULL);
            } else {
                ESP_LOGI(TAG, "ignored single click outside post-recording window");
            }
            break;
        case VIBE_STICK_EVENT_DOUBLE_CLICK:
            if (post_recording_action_available()) {
                post_simple_event("button_double", NULL);
                poll_state();
            } else {
                ESP_LOGI(TAG, "ignored double click outside post-recording window");
            }
            break;
        case VIBE_STICK_EVENT_LONG_START:
            (void)process_pending_long_start();
            break;
        case VIBE_STICK_EVENT_LONG_STOP:
            if (atomic_exchange(&s_long_stop_pending, false)) {
                handle_recording_stop();
            }
            break;
        case VIBE_STICK_EVENT_TOGGLE_VIEW:
            set_pet_view_visible(!s_pet_view_visible);
            break;
        }
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "boot %s version=%s build=%s %s transport=%s",
             FIRMWARE_NAME, FIRMWARE_VERSION, __DATE__, __TIME__, TRANSPORT);
    esp_err_t nvs = nvs_flash_init();
    if (nvs == ESP_ERR_NVS_NO_FREE_PAGES || nvs == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    } else {
        ESP_ERROR_CHECK(nvs);
    }

    ESP_ERROR_CHECK_WITHOUT_ABORT(vibe_board_init_power());
    s_event_queue = xQueueCreate(10, sizeof(agent_event_t));
    ESP_ERROR_CHECK(s_event_queue ? ESP_OK : ESP_ERR_NO_MEM);
    s_lvgl_lock = xSemaphoreCreateMutex();
    ESP_ERROR_CHECK(s_lvgl_lock ? ESP_OK : ESP_ERR_NO_MEM);
    ESP_ERROR_CHECK(init_display());
    lvgl_lock();
    create_ui();
    lvgl_unlock();
    (void)refresh_power_state();
    render_state();
    ESP_ERROR_CHECK(init_buttons());
    ESP_ERROR_CHECK(vibe_audio_init());
    ESP_ERROR_CHECK(init_wifi());
    BaseType_t app_task_created = xTaskCreate(app_task, "agent_app", 10240, NULL, 4, NULL);
    ESP_ERROR_CHECK(app_task_created == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);
}

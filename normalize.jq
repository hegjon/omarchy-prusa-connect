# Reshape a Prusa Connect /app/printers response into the flat model the widget
# renders. Every field Connect omits for an offline printer is optional here, so
# a sparse printer object normalizes without error rather than throwing.
#
#   jq -f normalize.jq < raw.json

def as_number($v): if ($v | type) == "number" then $v else null end;

# Connect reports two states that can disagree: connect_state is liveness,
# printer_state is the last thing the printer itself said, which may be stale by
# months. Liveness wins, so a printer that has been unplugged since February
# reads OFFLINE rather than showing a stale ATTENTION badge.
def effective_state:
  (.connect_state // "") as $connect
  | (.printer_state // "") as $printer
  | if $connect == "OFFLINE" or $connect == "" and $printer == "" then "OFFLINE"
    elif $connect == "OFFLINE" then "OFFLINE"
    elif $printer != "" then $printer
    elif $connect != "" then $connect
    else "UNKNOWN"
    end;

def tools_of:
  (.tools // {})
  | to_entries
  | map({
      index: (.key | tonumber? // .key),
      temp: as_number(.value.temp?),
      material: (.value.material? // null),
      nozzleDiameter: as_number(.value.nozzle_diameter?),
      fanHotend: as_number(.value.fan_hotend?),
      fanPrint: as_number(.value.fan_print?),
      hardened: (.value.hardened? // false),
      highFlow: (.value.high_flow? // false)
    })
  | sort_by(.index | tostring);

# Field names confirmed against a live printing MK4 on 2026-08-16; see
# test/fixtures/printing.json. The alternative spellings are kept because they
# cost nothing and Connect's APIs are not documented.
#
# progress is a PERCENTAGE, not a fraction: the captured sample reads 1.0 while
# weight_remaining is still 99% of model_weight. Passing it through unscaled is
# therefore correct, and scaling it by 100 would be wrong by 100x.
def job_of:
  (.job_info // .job // null)
  | if . == null or (type != "object") then null
    else
      {
        id: (.id? // null),
        name: (.display_name? // .name? // .file_name? // .path? // null),
        progress: as_number(.progress? // .progress_percent? // .percent?),
        remaining: as_number(.time_remaining? // .remaining_time? // .estimated_time_remaining?),
        elapsed: as_number(.time_printing? // .print_time? // .elapsed?)
      }
      # Connect has no estimate until the printer works one out, and signals that
      # with both 0 and -1 — the same job reported 0 at 117 seconds in and -1 at
      # 228. Rendering either as an ETA would be a lie ("ETA 0s" claims the job
      # is about to finish), so anything non-positive is unknown and the panel
      # omits the ETA. A print genuinely at zero flips to FINISHED within a poll.
      | if (.remaining != null and .remaining <= 0) then .remaining = null else . end
      | if (.id == null and .name == null and .progress == null) then null else . end
    end;

def attention_of:
  (.dialog_info // null)
  | if . == null or (type != "object") then null
    else { title: (.title? // null), text: (.text? // null), code: (.code? // null) }
    end;

# Which bundled illustration depicts this printer. The widget appends .svg and
# falls back to unknown.svg when a key has no file, so an unrecognised model
# degrades to a generic printer rather than a blank space.
#
# Connect derives its own artwork from a type enum plus flags for MMU and, on
# the XL, tool count. Only the model code and the tool map are exposed over the
# API, so this reconstructs what it can from those.
def asset_key:
  ((.printer_model // "") | ascii_downcase) as $model
  | ((.tools // {}) | length) as $tool_count
  | if $model == "" then "unknown"
    else
      # Input Shaper is a firmware trait, not a different chassis: MK4IS and MK4
      # are the same machine to look at, so both use mk4.svg.
      ($model | sub("is$"; "")) as $base
      | if ($base | startswith("xl")) then
          (if $tool_count > 1 then "xlmultitool" + ($tool_count | tostring) else "xl" end)
        else $base
        end
    end;

def printer_of:
  {
    uuid: (.uuid // null),
    name: (.name // .printer_type_name // "Printer"),
    model: (.printer_type_name // .printer_model // null),
    assetKey: asset_key,
    location: (.location // null),
    team: (.team_name // null),
    firmware: (.firmware // null),
    state: effective_state,
    printerState: (.printer_state // null),
    connectState: (.connect_state // null),
    online: ((.connect_state // "OFFLINE") != "OFFLINE"),
    lastOnline: as_number(.last_online),
    axisZ: as_number(.axis_z),
    speed: as_number(.speed),
    material: (.filament.material? // .tools["1"].material? // null),
    temps: (
      if (.temp | type) == "object" then
        {
          nozzle: as_number(.temp.temp_nozzle?),
          nozzleTarget: as_number(.temp.target_nozzle?),
          bed: as_number(.temp.temp_bed?),
          bedTarget: as_number(.temp.target_bed?)
        }
      else null end
    ),
    tools: tools_of,
    job: job_of,
    attention: attention_of
  }
  # A printer wanting a human is not always in the ATTENTION state: a dialog can
  # sit unanswered on the screen while the printer reports FINISHED. Defined once
  # here so the summary count, the bar badge and the notification rule cannot
  # drift apart.
  #
  # Only while reachable, though. An unreachable printer's dialog is as stale as
  # its printer_state, and badging the bar over something last seen in February
  # would be noise.
  | . + { needsAttention: (
      .state == "ATTENTION" or .state == "ERROR" or (.online and .attention != null)
    ) };

# Unreachable printers sink to the bottom: their detail is stale by definition,
# so they are the least worth reading first. Everything else keeps the order
# Connect sent, which is by name.
#
# Sorting entries by [group, original index] rather than calling sort_by on the
# printers directly keeps the within-group order explicit instead of resting on
# whether jq's sort happens to be stable.
def offline_last:
  to_entries
  | sort_by([(if .value.online then 0 else 1 end), .key])
  | map(.value);

(.printers // []) | map(printer_of) as $printers
| {
    printers: ($printers | offline_last),
    summary: {
      total: ($printers | length),
      online: ([$printers[] | select(.online)] | length),
      printing: ([$printers[] | select(.state == "PRINTING")] | length),
      attention: ([$printers[] | select(.needsAttention)] | length),
      finished: ([$printers[] | select(.state == "FINISHED")] | length),
      offline: ([$printers[] | select(.online | not)] | length)
    }
  }

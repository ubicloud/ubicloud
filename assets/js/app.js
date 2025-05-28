$(function () {
  setupAutoRefresh();
  setupDatePicker();
  setupFormOptionUpdates();
  setupPlayground();
  setupFormsWithPatchMethod();
  setupMetricsCharts();
});

$(".toggle-mobile-menu").on("click", function (event) {
  let menu = $("#mobile-menu")
  if (menu.is(":hidden")) {
    menu.show(0, function () {
      menu.toggleClass("mobile-menu-open")
    });
  } else {
    menu.toggleClass("mobile-menu-open")
    setTimeout(function () {
      menu.hide();
    }, 300);
  }
});

$(".cache-group-row").on("click", function (event) {
  let repository = $(this).data("repository");
  $(this).toggleClass("active");
  $(".cache-group-" + repository).toggleClass("hidden");
});


$(document).click(function () {
  $(".dropdown").removeClass("active");
});

$(".dropdown").on("click", function (event) {
  event.stopPropagation();
  $(this).toggleClass("active");
});

$(".toggle-parent-to-active").on("click", function (event) {
  $(this).parent().toggleClass("active");
});

$("#tag-membership-add tr, #tag-membership-remove tr").on("click", function (event) {
  let checkbox = $(this).find("input[type=checkbox]");
  if ($(event.target).is("input") || checkbox.prop("disabled")) {
    return;
  }
  checkbox.prop("checked", !checkbox.prop("checked"));
});

$("#ace-template").addClass('hidden');

var num_aces = 0;
$("#new-ace-btn").on("click", function (event) {
  event.preventDefault();
  num_aces++;
  var template = $('#ace-template').clone().removeClass('hidden').removeAttr('id');
  var pos = 0;
  var id_attr = '';
  template.find('select, input').each(function (i, element) {
    id_attr = 'ace-select-' + num_aces + '-' + pos;
    pos++;
    $(element).attr('id', id_attr);
  });
  template.find('label').attr('for', id_attr);
  template.insertBefore('#access-control-entries tbody tr:last');
});

$(".delete-btn").on("click", function (event) {
  event.preventDefault();
  let url = $(this).data("url");
  let csrf = $(this).data("csrf");
  let confirmation = $(this).data("confirmation");
  let confirmationMessage = $(this).data("confirmation-message");
  let redirect = $(this).data("redirect");
  let method = $(this).data("method");

  if (confirmation) {
    if (prompt(`Please type "${confirmation}" to confirm deletion`, "") != confirmation) {
      alert("Could not confirm resource name");
      return;
    }
  } else if (!confirm(confirmationMessage || "Are you sure to delete?")) {
    return;
  }

  $.ajax({
    url: url,
    type: method || "DELETE",
    data: { "_csrf": csrf },
    dataType: "json",
    headers: { "Accept": "application/json" },
    success: function (result) {
      window.location.href = redirect;
    },
    error: function (xhr, ajaxOptions, thrownError) {
      if (xhr.status == 404) {
        window.location.href = redirect;
        return;
      }

      let message = thrownError;
      try {
        response = JSON.parse(xhr.responseText);
        message = response.error?.message
      } catch { };
      alert(`Error: ${message}`);
    }
  });
});

$(".edit-inline-btn").on("click", function (event) {
  let fields = $(this).data("fields");

  let row = $(this).closest("tr");
  let currentFieldId = 0;
  row.find("td.inline-editable").each(function () {
    let name = fields[currentFieldId];
    let value = $(this).text().trim();

    let input = $("<input>", {
      type: "text",
      name: name,
      value: value,
      "data-original-value": value,
      class: "w-full rounded-md border-0 py-1.5 pl-3 pr-10 shadow-sm ring-1 ring-inset focus:ring-2 focus:ring-inset sm:text-sm sm:leading-6 text-gray-900 ring-gray-300 placeholder:text-gray-400 focus:ring-orange-600"});
    $(this).html(input);

    currentFieldId++;
  });

  row.addClass("active");
});

$(".cancel-inline-btn").on("click", function (event) {
  let row = $(this).closest("tr");
  row.find("td.inline-editable").each(function () {
    let originalValue = $(this).find("input").data("original-value");
    $(this).text(originalValue);
  });
  row.removeClass("active");
});

$(".save-inline-btn").on("click", function (event) {
  let row = $(this).closest("tr");
  let data = {};
  row.find("td.inline-editable input").each(function () {
    data[$(this).attr("name")] = $(this).val();;
  });

  let url = $(this).data("url");
  let csrf = $(this).data("csrf");
  let confirmation_message = $(this).data("confirmation-message");

  $.ajax({
    url: url,
    type: "PATCH",
    data: { "_csrf": csrf, ...data },
    dataType: "json",
    headers: { "Accept": "application/json" },
    success: function (result) {
      row.find("td.inline-editable").each(function () {
        let value = $(this).find("input").val();
        $(this).text(value);
      });
      row.removeClass("active");
      alert(confirmation_message);
    },
    error: function (xhr, ajaxOptions, thrownError) {
      let message = thrownError;
      try {
        response = JSON.parse(xhr.responseText);
        message = response.error?.message
      } catch { };
      alert(`Error: ${message}`);
    }
  });
});

$(".restart-btn").on("click", function (event) {
  if (!confirm("Are you sure to restart?")) {
    event.preventDefault();
  }
});

$(".copyable-content").on("click", ".copy-button", function (event) {
  let parent = $(this).parent();
  let content = parent.data("content");
  let message = parent.data("message");
  navigator.clipboard.writeText(content);

  if (message) {
    notification(message);
  }
})

$(".revealable-content").on("click", ".reveal-button", function (event) {
  $(this).parent().hide();
  $(this).parent().siblings(".revealed-content").show();
})

$(".revealable-content").on("click", ".hide-button", function (event) {
  $(this).parent().hide();
  $(this).parent().siblings(".shadow-content").show();
})

$(".back-btn").on("click", function (event) {
  event.preventDefault();
  history.back();
})

function notification(message) {
  let container = $("#notification-template").parent();
  let newNotification = $("#notification-template").clone();
  newNotification.find("p").text(message);
  newNotification.appendTo(container).show(0, function () {
    $(this)
      .removeClass("translate-y-2 opacity-0 sm:translate-y-0 sm:translate-x-2")
      .addClass("translate-y-0 opacity-100 sm:translate-x-0");
  });

  setTimeout(function () {
    newNotification.remove();
  }, 2000);
}

function setupAutoRefresh() {
  $("div.auto-refresh").each(function () {
    const interval = $(this).data("interval");
    setTimeout(function () {
      location.reload();
    }, interval * 1000);
  });
}

function setupDatePicker() {
  if (!$.prototype.flatpickr) { return; }

  $(".datepicker").each(function () {
    let options = {
      enableTime: true,
      time_24hr: true,
      altInput: true,
      altFormat: "F j, Y H:i \\U\\T\\C",
      dateFormat: "Y-m-d H:i",
      monthSelectorType: "static",
      parseDate(dateStr, dateFormat) {
        // flatpicker uses browser timezone, but we want to customer to select UTC
        date = new Date(dateStr);
        return new Date(date.getUTCFullYear(), date.getUTCMonth(),
          date.getUTCDate(), date.getUTCHours(),
          date.getUTCMinutes(), date.getUTCSeconds());
      }
    };

    if ($(this).data("maxdate")) {
      options.maxDate = $(this).data("maxdate");
    }
    if ($(this).data("mindate")) {
      options.minDate = $(this).data("mindate");
    }
    if ($(this).data("defaultdate")) {
      options.defaultDate = $(this).data("defaultdate");
    }

    $(this).flatpickr(options);
  });
}

function setupFormOptionUpdates() {
  $('#creation-form').on('change', 'input', function () {
    let name = $(this).attr('name');
    option_dirty[name] = $(this).val();

    if ($(this).attr('type') !== 'radio') {
      return;
    }
    redrawChildOptions(name);
  });
}

function redrawChildOptions(name) {
  if (option_children[name]) {
    let value = $("input[name=" + name + "]:checked").val();
    let classes = $("input[name=" + name + "]:checked").parent().attr('class');
    classes = classes ? classes.split(" ") : [];
    classes = "." + classes.concat("form_" + name, "form_" + name + "_" + value).join('.');

    option_children[name].forEach(function (child_name) {
      let child_type = document.getElementsByName(child_name)[0].nodeName.toLowerCase();
      if (child_type == "input") {
        child_type = "input_" + document.getElementsByName(child_name)[0].type.toLowerCase();
      }

      let elements2select = [];
      switch (child_type) {
        case "input_radio":
          $("input[name=" + child_name + "]").parent().hide()
          $("input[name=" + child_name + "]").prop('disabled', true).prop('checked', false).prop('selected', false);
          $("input[name=" + child_name + "]").parent(classes).show()
          $("input[name=" + child_name + "]").parent(classes).children("input[name=" + child_name + "]").prop('disabled', false);

          if (option_dirty[child_name]) {
            elements2select = $("input[name=" + child_name + "][value=" + option_dirty[child_name] + "]").parent(classes);
          }

          if (elements2select.length == 0) {
            option_dirty[child_name] = null;
            elements2select = $("input[name=" + child_name + "]").parent(classes);
          }

          elements2select[0].children[0].checked = true;
          break;
        case "input_checkbox":

          break;
        case "select":
          $("select[name=" + child_name + "]").children().hide().prop('disabled', true).prop('checked', false).prop('selected', false);
          $("select[name=" + child_name + "]").children(".always-visible, " + classes).show().prop('disabled', false);

          if (option_dirty[child_name]) {
            elements2select = $("select[name=" + child_name + "]").children(classes + "[value=" + option_dirty[child_name] + "]");
          }

          if (elements2select.length == 0) {
            option_dirty[child_name] = null;
            elements2select = $("select[name=" + child_name + "]").children(".always-visible, " + classes);
          }

          elements2select[0].selected = true;
          break;
      }

      redrawChildOptions(child_name);
    });
  }
}

function setupPlayground() {
  if ($(document).attr('title') !== 'Ubicloud - Playground') {
    return;
  }

  function show_tab(name) {
    $(".inference-tab").removeClass("active");
    $(".inference-response").hide();
    $(`#inference_tab_${name}`).show().parent().addClass("active");
    $(`#inference_response_${name}`).show().removeClass("max-h-96");
  }

  $(".inference-tab").on("click", function (event) {
    show_tab($(this).data("target"));
  });

  $('#inference_tab_preview').hide();

  let controller = null;

  const reasoningExtension = {
    name: "reasoning",
    level: "block",
    format_reasoning(text) {
      text = text.trim().replace(/\n+/g, '<br>');
      if (text.length > 0) {
        return `
          <div class="text-sm italic p-4 bg-gray-50 ">
            <div class="font-bold mb-4">Reasoning</div>
            ${text}
          </div>`;
      }
      return "";
    },
    tokenizer(src) {
      const match = src.match(/^<think>([\s\S]+?)(?:<\/think>|$)/);
      if (match) {
        return {
          type: "reasoning",
          raw: match[0],
          text: match[1].trim(),
        };
      }
      return false;
    },
    renderer(token) {
      if (token.type === "reasoning") {
        return reasoningExtension.format_reasoning(token.text);
      }
    }
  };
  marked.use({ extensions: [reasoningExtension] });

  const generate = async () => {
    if (controller) {
      controller.abort();
      $('#inference_submit').text("Submit");
      controller = null;
      return;
    }

    const prompt = $('#inference_prompt').val();
    const endpoint = $('#inference_endpoint').val();
    const api_key = $('#inference_api_key').val();

    if (!prompt) {
      alert("Please enter a prompt.");
      return;
    }
    if (!endpoint) {
      alert("Please select an inference endpoint.");
      return;
    }
    if (!api_key) {
      alert("Please select an inference api key.");
      return;
    }

    $('#inference_response_raw').text("");
    $('#inference_response_preview').text("");
    $('#inference_submit').text("Stop");
    show_tab("raw");
    $('#inference_tab_preview').hide();
    $('#inference_response_raw').addClass("max-h-96");

    controller = new AbortController();
    const signal = controller.signal;
    let content = "";
    let reasoning_content = ""

    try {
      const response = await fetch(`${endpoint}/v1/chat/completions`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${api_key}`,
        },
        body: JSON.stringify({
          model: $('#inference_endpoint option:selected').text().trim(),
          messages: [{ role: "user", content: prompt }],
          stream: true,
        }),
        signal,
      });

      if (!response.ok) {
        throw new Error(`Response status: ${response.status}`);
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder("utf-8");
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop(); // Save last (possibly incomplete) line for next iteration.

        // At the end of stream, buffer will either be empty or contain only '[DONE]',
        // because all complete lines would have been processed and '[DONE]' is a full line.
        // So there is no need to flush or process the buffer after the loop.

        const parsedLines = lines
          .filter((line) => line.startsWith("data:"))
          .map((line) => line.slice(5).trim())
          .filter((line) => line !== "" && line !== "[DONE]")
          .map((line) => { try { return JSON.parse(line); } catch { return null; } })
          .filter((x) => x !== null);

        parsedLines.forEach((parsedLine) => {
          const new_content = parsedLine?.choices?.[0]?.delta?.content;
          const new_reasoning_content = parsedLine?.choices?.[0]?.delta?.reasoning_content;
          if (!new_content && !new_reasoning_content) {
            return;
          }
          content += new_content || "";
          reasoning_content += new_reasoning_content || "";
          const inference_response_raw = reasoning_content
            ? `[reasoning_content]\n${reasoning_content}\n\n[content]\n${content}`
            : content;
          $('#inference_response_raw').text(inference_response_raw);
        });
      }
      const inference_response_preview = DOMPurify.sanitize(
        reasoningExtension.format_reasoning(reasoning_content) + marked.parse(content));
      $('#inference_response_preview').html(inference_response_preview);
      show_tab("preview");
    }
    catch (error) {
      let errorMessage;

      if (signal.aborted) {
        errorMessage = "Request aborted.";
      } else if (error instanceof TypeError && error.message === "Failed to fetch") {
        errorMessage = "Unable to get a response from the endpoint. This may be due to network connectivity or permission-related issues.";
      } else {
        errorMessage = `An error occurred: ${error.message}`;
      }

      $('#inference_response_raw').text(errorMessage);
    } finally {
      $('#inference_submit').text("Submit");
      controller = null;
    }
  };

  $('#inference_submit').on("click", generate);
}

function setupFormsWithPatchMethod() {
  $("#creation-form.PATCH").on("submit", function (event) {
    event.preventDefault();

    var form = $(this);
    var jsonData = {};
    form.serializeArray().forEach(function(item) {
        jsonData[item.name] = item.value;
    });

    $.ajax({
        url: form.attr('action'),
        type: 'PATCH',
        dataType: "html",
        data: jsonData,
        success: function (response, status, xhr) {
          var redirectUrl = xhr.getResponseHeader('Location');
          if (redirectUrl) {
              window.location.href = redirectUrl;
          }
        },
        error: function (xhr, ajaxOptions, thrownError) {
          let message = thrownError;
          alert(`Error: ${message}`);
        }
    });
  });
}

const metricsCharts = [];
const colorPalette = [
  {
    color: '#5470c6',
    class: 'blue-600'
  },
  {
    color: '#91cc75',
    class: 'green-400'
  },
  {
    color: '#fac858',
    class: 'amber-400'
  },
  {
    color: '#ee6666',
    class: 'red-400'
  },
  {
    color: '#73c0de',
    class: 'sky-300'
  },
  {
    color: '#3ba272',
    class: 'emerald-600'
  },
  {
    color: '#fc8452',
    class: 'orange-500',
  }
];

function setupMetricsCharts() {
  const metricsContainer = document.querySelector('#metrics-container');
  if (!metricsContainer) {
    return;
  }

  const charts = document.querySelectorAll('#metrics-container [id$="-chart"]');

  charts.forEach(chart => {
    const metricKey = chart.getAttribute('data-metric-key');
    const chartInstance = {
      key: metricKey,
      unit: chart.getAttribute('data-metric-unit'),
      chart: echarts.init(chart)
    };
    metricsCharts.push(chartInstance);
    setupInitialChartOptions(chartInstance);
  });

  updateMetricsCharts();

  $('#metrics-container #time-range').on('change', updateMetricsCharts);
  $('#metrics-container #refresh-button').on('click', updateMetricsCharts);

  // Reload charts every 5 minutes.
  setInterval(updateMetricsCharts, 5 * 60 * 1000);
}

function setupInitialChartOptions(chartInstance) {
  const options = {
    color: colorPalette.map(p => p.color),
    tooltip: {
      trigger: 'axis',
      formatter: function(params) {
        const isoDate = toLocalISOString(new Date(params[0].value[0]));

        // Build the tooltip HTML
        let html = `<strong>${isoDate}</strong><br/>`;
        params.forEach((item) => {
          const value = unitFormatter(chartInstance.unit, 2)(item.value[1]);
          // Use the series color for the marker
          const colorClass = colorPalette[item.componentIndex % colorPalette.length].class;
          html += `
            <span class="text-${colorClass} text-right">● ${item.seriesName}</span><span class="ml-2">${value}<br/></span>
          `;
        });
        return html;
      }
    },
    xAxis: {
      type: 'time',
      splitLine: { show: true },
      axisLabel: {
        hideOverlap: true
      }
    },
    yAxis: {
      type: 'value',
      axisLabel: {
        formatter: unitFormatter(chartInstance.unit),
        showMaxLabel: chartInstance.unit === "%"
      },
      min: 0,
      max: (chartInstance.unit === "%") ? 100 : function (value) {
        return Math.max(10, Math.round(1.1 * value.max))
      }
    },
    grid: {
      containLabel: true,
      left: '0%',
      right: '2%',
      top: '10%',
      bottom: '0%',
    },
  }

  chartInstance.chart.setOption(options);

  window.addEventListener('resize', debounce(chartInstance.chart.resize, 300));
}

function queryAndUpdateChart(chartInstance, start_time, end_time) {
  const metricKey = chartInstance.key;
  const params = {
    key: metricKey,
    start: start_time.toISOString(),
    end: end_time.toISOString()
  }
  const queryString = new URLSearchParams(params).toString();
  const url = `${document.location.href}/metrics?${queryString}`;

  fetch(url)
    .then(response => response.json())
    .then(data => {
      const metrics = data.metrics || [];

      if (metrics.length === 0) {
        console.warn(`No metrics found for ${metricKey}`);
        return;
      }

      const metric = metrics[0];
      const chartSeries = [];

      for (const series of metric["series"]) {
        const values = series["values"];
        const seriesData = values.map(item => {
          const ts = item[0] * 1000;
          const value = Number(Number(item[1]).toFixed(2));
          return [ts, value]
        });
        const labelKeys = Object.keys(series["labels"]);
        const firstKey = labelKeys[0];
        const seriesName = series["labels"][firstKey] || series["labels"]["name"] || metric["name"];

        chartSeries.push({
          name: seriesName,
          type: 'line',
          data: seriesData,
          symbol: 'circle',
          smooth: true,
          itemStyle: {
            opacity: 0,
          },
          emphasis: {
            itemStyle: {
              opacity: 1,
            },
          },
        });
      }

      chartInstance.chart.hideLoading();
      chartInstance.chart.setOption({
        legend: {
          data: chartSeries.map(series => series.name),
          right: '2%',
        },
        xAxis: {
          type: 'time',
          min: start_time.getTime(),
          max: end_time.getTime()
        },
        series: chartSeries
      });
      chartInstance.chart.resize();
    })
    .catch(error => {
      chartInstance.chart.hideLoading();
      chartInstance.chart.setOption({
        graphic: {
          type: 'text',
          left: 'center',
          top: 'middle',
          style: {
            text: 'Failed to load data. Please refresh the charts to try again.',
            fontSize: 18,
            fill: '#c00'
          }
        }
      });

      console.error(`Error fetching data for ${metricKey}: ${error}`)
    });
}

function updateMetricsCharts() {
  const timeDuration = $('#metrics-container #time-range').val();
  const timeDurationSeconds = durationToSeconds(timeDuration);
  const start_time = new Date(Date.now() - timeDurationSeconds * 1000);
  const end_time = new Date(Date.now());

  for (const chartInstance of metricsCharts) {
    chartInstance.chart.showLoading();
    queryAndUpdateChart(chartInstance, start_time, end_time);
  }
}

function durationToSeconds(durationStr) {
  const units = {
    "s": 1,
    "m": 60,
    "h": 60 * 60,
    "d": 24 * 60 * 60,
  };
  const count = parseInt(durationStr.slice(0, -1));
  const unit = durationStr.slice(-1);
  if (isNaN(count) || !units[unit]) {
    throw new Error("Invalid duration format");
  }
  return count * units[unit];
}

function bytesFormatter(unit, precision) {
  const unitParts = unit.split('/');
  const suffix = unitParts.length > 1 ? "/" + unitParts[1] : "";

  return function (value, index) {
    if (value >= 1024 ** 4) return flexiblePrecision(value / (1024 ** 4), precision) + ' TiB' + suffix;
    if (value >= 1024 ** 3) return flexiblePrecision(value / (1024 ** 3), precision) + ' GiB' + suffix;
    if (value >= 1024 ** 2) return flexiblePrecision(value / (1024 ** 2), precision) + ' MiB' + suffix;
    if (value >= 1024) return flexiblePrecision(value / 1024, precision) + ' KiB' + suffix;
    return value + ' bytes' + suffix;
  }
}

function opsFormatter(unit, precision) {
  const unitParts = unit.split('/');
  const suffix = unitParts.length > 1 ? "/" + unitParts[1] : "";
  const unitName = unitParts[0];

  return function (value, index) {
    if (value >= 1000 ** 3) return flexiblePrecision(value / (1000 ** 3), precision)+ ' G ' + unitName + suffix;
    if (value >= 1000 ** 2) return flexiblePrecision(value / (1000 ** 2), precision)+ ' M ' + unitName + suffix;
    if (value >= 1000) return flexiblePrecision(value / 1000, precision) + ' K ' + unitName + suffix;
    return value + ' ' + unitName + suffix;
  }
}

function unitFormatter(unit, precision = 0) {
  if (unit.startsWith("bytes")) {
    return bytesFormatter(unit, precision);
  } else if (unit == "IOPS" || unit.startsWith("ops") || unit.startsWith("count") || unit.startsWith("deadlock")) {
    return opsFormatter(unit, precision);
  } else {
    return function (value, index) {
      return value + ' ' + unit;
    }
  }
}

function toLocalISOString(date) {
  const pad = n => String(n).padStart(2, '0');
  const tz = -date.getTimezoneOffset();
  const sign = tz >= 0 ? '+' : '-';
  const tzH = pad(Math.floor(Math.abs(tz) / 60));
  const tzM = pad(Math.abs(tz) % 60);
  return (
    date.getFullYear() + '-' +
    pad(date.getMonth() + 1) + '-' +
    pad(date.getDate()) + 'T' +
    pad(date.getHours()) + ':' +
    pad(date.getMinutes()) + ':' +
    pad(date.getSeconds())
  );
}

function debounce(callback, delay = 1000) {
  let timeout;
  return (...args) => {
    clearTimeout(timeout);
    timeout = setTimeout(() => {
      callback(...args);
    }, delay);
  };
}

// Increase precision for values less than 10 if using 0 precision, to not
// repeat the same single-digit axis value multiple times.
function flexiblePrecision(value, precision) {
  const increasedPrecision = Math.max(1, precision);

  return (value < 10) ? value.toFixed(increasedPrecision) : value.toFixed(precision);
}

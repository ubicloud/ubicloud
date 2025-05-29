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
  let inline_editable_group = $(this).closest(".group\\/inline-editable");
  inline_editable_group.find(".inline-editable").each(function () {
    let value = $(this).find(".inline-editable-text").text();
    $(this).find(".inline-editable-input").val(value);
  });

  inline_editable_group.addClass("active");
});

$(".cancel-inline-btn").on("click", function (event) {
  $(this).closest(".group\\/inline-editable").removeClass("active");
});

$(".save-inline-btn").on("click", function (event) {
  let inline_editable_group = $(this).closest(".group\\/inline-editable");
  let data = {};
  inline_editable_group.find(".inline-editable-input").each(function () {
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
      inline_editable_group.find(".inline-editable").each(function () {
        let value = $(this).find(".inline-editable-input").val();
        $(this).find(".inline-editable-text").text(value);
      });

      inline_editable_group.removeClass("active");

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

$(".revealable-button").on("click", function () {
  $(this).closest(".revealable-content").toggleClass("active");
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

$(".fork-icon").on("click", function () {
  let target_datetime = $(this).data("target-datetime");
  date_picker = flatpickr("#restore_target", {enableTime: true, dateFormat: "Y-m-d H:i"})
  date_picker.setDate(target_datetime, true);

  $("#restore_target").addClass("animate-flash transition-colors duration-1000");
  setTimeout(() => {
    $("#restore_target").removeClass('animate-flash');
  }, 2000);
})

$(".connection-info-format-selector select, .connection-info-format-selector input").on('change', function() {
  let format = $(".connection-info-format-selector select").val();
  let port = $(".connection-info-format-selector input").is(":checked") ? "6432" : "5432";
  let reveal_status = $(".connection-info-box:visible").find(".group").hasClass('active')

  $(".connection-info-box").hide();
  $(".connection-info-box-" + format + "-" + port).find(".group").toggleClass('active', reveal_status);
  $(".connection-info-box-" + format + "-" + port).show();
});


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

  const previous_messages = [];
  const previous_message_containers = [];

  // Initialize the model selector based on the location hash.
  const hash = window.location.hash.slice(1);
  if (hash !== '') {
    const $select = $('#inference_endpoint');
    const $option = $select.find('option').filter(function () {
      return $(this).data('id') === hash;
    });
    if ($option.length > 0) {
      $select.val($option.val()).trigger('change');
    }
  }

  // Disable the file input if the selected model is not multimodal.
  function update_file_input_state() {
    const selected_option = $('#inference_endpoint option:selected');
    const tags = JSON.parse(selected_option.attr('data-tags') || '{}');
    const is_multimodal = tags['multimodal'] || false;
    $('#inference_files').prop('disabled', !is_multimodal);
  }
  update_file_input_state();
  $('#inference_endpoint').on('change', update_file_input_state);

  $("#inference_new_chat").click(() => {
    for (const container of previous_message_containers) {
      container.remove();
    }
    previous_messages.splice(0);
    previous_message_containers.splice(0);
    $("#inference_previous_empty").show();
  });

  // Show reasoning in a different style.
  const reasoningExtension = {
    name: "reasoning",
    level: "block",
    format_reasoning(text) {
      text = text.trim().replace(/\n+/g, '<br>');
      if (text.length > 0) {
        return `
          <div class="text-sm italic p-4 bg-gray-50 mb-2">
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

  function readFileAsDataURL(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = reject;
      reader.readAsDataURL(file);
    });
  }
  async function readFilesFromInput(input) {
    if (input.disabled) {
      return [];
    }
    const files = Array.from(input.files);
    const contents = [];
    for (const file of files) {
      const result = await readFileAsDataURL(file);
      const mimeType = file.type;
      if (mimeType.startsWith("image/")) {
        contents.push({
          type: "image_url",
          image_url: { url: result },
        });
      } else if (mimeType === "application/pdf") {
        contents.push({
          type: "file",
          file: { filename: file.name, file_data: result },
        });
      } else {
        throw new Error(`Unsupported file type ${mimeType} for file ${file.name}. Only images and PDFs are supported.`);
      }
    }
    return contents;
  }

  function appendMessage(message, show_processing = false) {
    const role = message.role;
    const text = message.content[0].text;
    const message_id = previous_messages.length;
    // The `clipboard-document` and `check` icons from https://heroicons.com.
    const COPY_ICON = '<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 17.25v3.375c0 .621-.504 1.125-1.125 1.125h-9.75a1.125 1.125 0 0 1-1.125-1.125V7.875c0-.621.504-1.125 1.125-1.125H6.75a9.06 9.06 0 0 1 1.5.124m7.5 10.376h3.375c.621 0 1.125-.504 1.125-1.125V11.25c0-4.46-3.243-8.161-7.5-8.876a9.06 9.06 0 0 0-1.5-.124H9.375c-.621 0-1.125.504-1.125 1.125v3.5m7.5 10.375H9.375a1.125 1.125 0 0 1-1.125-1.125v-9.25m12 6.625v-1.875a3.375 3.375 0 0 0-3.375-3.375h-1.5a1.125 1.125 0 0 1-1.125-1.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H9.75"></path>';
    const CHECK_ICON = '<path stroke-linecap="round" stroke-linejoin="round" d="m4.5 12.75 6 6 9-13.5" />';
    const PROCESSING_STATUS = "<span class='mask-sweep'>Processing...</span>";
    const num_files = message.content.length - 1;
    const $new_message = $(`
      <div class="mt-6 first:mt-2">
        <div class="inline-flex items-baseline rounded-full px-2 text-xs font-semibold leading-5 bg-gray-200 text-gray-800">${role}</div>
        <div id="inference_message_${message_id}" class="mt-2 text-sm ml-2">${text}</div>
        <div class="text-sm ml-2 mt-1 text-gray-500">${num_files > 0 ? `Attached ${num_files} file(s).` : ""}</div>
        <div id="inference_message_info_${message_id}" class="text-sm ml-2 mt-1 text-gray-500">${show_processing ? PROCESSING_STATUS : ""}</div>
        <div class="flex mt-2 gap-1 ml-2 items-center">
          <div id="copy_inference_message_${message_id}" class="group inline-block text-gray-400 hover:text-black cursor-pointer">
            <svg id="inference_icon_${message_id}" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor" class="h-4 w-4">
              ${COPY_ICON}
            </svg>
          </div>
        </div>
      </div>
    `);
    $("#inference_previous_empty").hide();
    $("#inference_previous").append($new_message);
    previous_message_containers.push($new_message);
    previous_messages.push(message);
    let timeout = undefined;
    $(`#copy_inference_message_${message_id}`).click(() => {
      const content = previous_messages[message_id].content[0].text;
      window.navigator.clipboard.writeText(content);
      $(`#inference_icon_${message_id}`).html(CHECK_ICON);
      clearTimeout(timeout);
      timeout = setTimeout(() => {
        $(`#inference_icon_${message_id}`).html(COPY_ICON);
      }, 1000);
    });
  }

  let controller = null;
  const generate = async () => {
    if (controller) {
      controller.abort();
      $('#inference_submit').text("Submit");
      $('#inference_files').prop('disabled', false);
      controller = null;
      return;
    }

    const system = $('#inference_system').val();
    const prompt = $('#inference_prompt').val();
    const endpoint = $('#inference_endpoint').val();
    const api_key = $('#inference_api_key').val();
    const temperature = parseFloat($('#inference_temperature').val()) || 1.0;
    const top_p = parseFloat($('#inference_top_p').val()) || 1.0;

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

    const messages = [];
    if (system.length > 0) {
      messages.push({ role: "system", content: system });
    }
    messages.push(...previous_messages);
    let file_contents;
    try {
      file_contents = await readFilesFromInput(document.getElementById('inference_files'));
    } catch (error) {
      alert(`Failed to read file(s): ${error.message || error}`);
      return;
    }
    const user_message = {
      role: "user", content: [
        { type: "text", text: prompt },
        ...file_contents,
      ]
    };
    messages.push(user_message);
    const payload = JSON.stringify({
      model: $("#inference_endpoint option:selected").text().trim(),
      messages: messages,
      stream: true,
      stream_options: { include_usage: true },
      temperature: temperature,
      top_p: top_p,
    });

    const MAX_PAYLOAD_MB = 50;
    if (payload.length > MAX_PAYLOAD_MB << 20) {
      alert(`The request payload is too large (${payload.length >> 20} MB).`
        + ` Please reduce the size to less than ${MAX_PAYLOAD_MB} MB.`);
      return;
    }

    $("#inference_submit").text("Stop");
    $("#inference_files").prop('disabled', true);
    $("#inference_prompt").val("");
    $("#inference_files").val("");
    appendMessage(user_message);
    appendMessage({
      role: "assistant",
      content: [
        { type: "text", text: "" }, // Placeholder for the response content.
      ]
    }, show_processing = true);
    const assistant_message_id = previous_messages.length - 1;
    const assistant_message = previous_messages[assistant_message_id];
    const $assistant_message_container = $(`#inference_message_${assistant_message_id}`);

    controller = new AbortController();
    const signal = controller.signal;
    let content = "";
    let reasoning_content = "";
    let showing_processing = true;

    try {
      const response = await fetch(`${endpoint}/v1/chat/completions`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${api_key}`,
        },
        body: payload,
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
          const prompt_tokens = parsedLine?.usage?.prompt_tokens;
          const completion_tokens = parsedLine?.usage?.completion_tokens;
          if (prompt_tokens !== undefined && completion_tokens !== undefined) {
            $(`#inference_message_info_${assistant_message_id}`).text(`Usage: ${prompt_tokens} input tokens and ${completion_tokens} output tokens.`);
          }
          const new_content = parsedLine?.choices?.[0]?.delta?.content;
          const new_reasoning_content = parsedLine?.choices?.[0]?.delta?.reasoning_content;
          if (!new_content && !new_reasoning_content) {
            return;
          }
          content += new_content || "";
          reasoning_content += new_reasoning_content || "";
          assistant_message.content[0].text = content;

          // Scroll to the bottom of the page if the user is near the bottom.
          const scrollTop = window.scrollY || document.documentElement.scrollTop;
          if (document.documentElement.scrollHeight - (scrollTop + window.innerHeight) <= 1) {
            requestAnimationFrame(() => {
              window.scrollTo({ top: document.documentElement.scrollHeight });
            });
          }

          const rendered_response = DOMPurify.sanitize(
            reasoningExtension.format_reasoning(reasoning_content) + marked.parse(content));
          $assistant_message_container.html(rendered_response);
          if (showing_processing) {
            $(`#inference_message_info_${assistant_message_id}`).text("");
            showing_processing = false;
          }
        });
      }
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

      $(`#inference_message_info_${assistant_message_id}`).text(errorMessage);
    } finally {
      $("#inference_submit").text("Submit");
      $("#inference_files").prop("disabled", false);
      controller = null;
    }
  };

  $('#inference_submit').on("click", generate);
  $('#inference_config-show_advanced-0').on("change", function() {
    $('#inference_config_advanced_settings').toggleClass("hidden", !$(this).is(":checked"));
  });
}

function setupFormsWithPatchMethod() {
  $("#creation-form.PATCH").on("submit", function (event) {
    event.preventDefault();

    var form = $(this);
    var jsonData = {};
    form.serializeArray().forEach(function (item) {
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
      formatter: function (params) {
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
  const url = $("#metrics-container").data("metrics-url") + "/metrics?" + queryString;

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
  const timeDuration = $('#metrics-container #time-range').val() || "1h";
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
    if (value >= 1000 ** 3) return flexiblePrecision(value / (1000 ** 3), precision) + ' G ' + unitName + suffix;
    if (value >= 1000 ** 2) return flexiblePrecision(value / (1000 ** 2), precision) + ' M ' + unitName + suffix;
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

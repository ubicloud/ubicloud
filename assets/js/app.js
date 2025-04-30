$(function () {
  setupAutoRefresh();
  setupDatePicker();
  setupFormOptionUpdates();
  setupPlayground();
  setupFormsWithPatchMethod()
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

$(".sidebar-group-btn").on("click", function (event) {
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
$(function () {
  setupPolicyEditor();
  setupAutoRefresh();
  setupDatePicker();
  setupFormOptionUpdates();
  setupInferencePlayground();
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

$(".delete-btn").on("click", function (event) {
  event.preventDefault();
  let url = $(this).data("url");
  let csrf = $(this).data("csrf");
  let confirmation = $(this).data("confirmation");
  let confirmationMessage = $(this).data("confirmation-message");
  let redirect = $(this).data("redirect");
  let method = $(this).data("method");

  if (!confirm(confirmationMessage || "Are you sure to delete?")) {
    return;
  }

  if (confirmation && prompt(`Please type "${confirmation}" to confirm deletion`, "") != confirmation) {
    alert("Could not confirm resource name");
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

function setupPolicyEditor() {
  $(".policy-editor").each(function () {
    let pre = $(this).find("pre");
    let textarea = $(this).find("textarea");
    pre.html(jsonHighlight(DOMPurify.sanitize(pre.text())));

    pre.on("focusout", function () {
      pre.html(jsonHighlight(DOMPurify.sanitize(pre.text())));
    })

    pre.on("keyup", function () {
      textarea.val(pre.text());
    })
  });
}

function setupInferencePlayground() {
  const aiPrompt = document.getElementById("ai-prompt");
  const aiSubmit = document.getElementById("ai-submit");
  const aiStop = document.getElementById("ai-stop");
  const aiResponse = document.getElementById("ai-response");
  const aiToken = document.getElementById("ai-token");
  const aiModel = document.getElementById("ai-model");

  const generate = async () => {
    // Alert the user if no prompt value
    if (!aiPrompt.value) {
      alert("Please enter a prompt.");
      return;
    }

    if (!aiModel.value) {
      alert("Please select an inference model.");
      return;
    }

    if (!aiToken.value) {
      alert("Please select an inference token.");
      return;
    }

    // Disable the generate button and enable the stop button
    aiSubmit.disabled = true;
    aiStop.disabled = false;
    aiResponse.innerText = "Generating...";

    // Create a new AbortController instance
    controller = new AbortController();
    const signal = controller.signal;

    try {
      // Fetch the response from the OpenAI API with the signal from AbortController
      const response = await fetch("https://llama-3-2-3b-it.ai.ubicloud.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer abc`,
        },
        body: JSON.stringify({
          model: aiModel[aiModel.selectedIndex].text,
          messages: [{ role: "user", content: aiPrompt.value }],
          max_tokens: 1000,
          stream: true, // For streaming responses
        }),
        signal, // Pass the signal to the fetch request
      });

      // Read the response as a stream of data
      const reader = response.body.getReader();
      const decoder = new TextDecoder("utf-8");
      aiResponse.innerText = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        // Massage and parse the chunk of data
        const chunk = decoder.decode(value);
        const lines = chunk.split("\n");

        const parsedLines = lines
          //.map((line) => line.replace(/\n+$/, ""))
          //.map((line) => line.replace(/^\n+/, ""))
          .map((line) => line.replace(/^data: /, "")) // Remove the "data: " prefix
          .filter((line) => !line.includes("usage_data"))
          .filter((line) => line !== "" && line !== "[DONE]")
          .map((line) => JSON.parse(line)); // Parse the JSON string

        for (const parsedLine of parsedLines) {
          const { choices } = parsedLine;
          const { delta } = choices[0];
          const { content } = delta;
          // Update the UI with the new content
          if (content) {
            aiResponse.innerText += content;
          }
        }
      }
    } catch (error) {
      // Handle fetch request errors
      if (signal.aborted) {
        aiResponse.innerText = "Request aborted.";
      } else {
        console.error("Error:", error);
        //aiResponse.innerText = "Error occurred while generating.";
      }
    } finally {
      // Enable the generate button and disable the stop button
      aiSubmit.disabled = false;
      aiStop.disabled = true;
      controller = null; // Reset the AbortController instance
    }
  };

  const stop = () => {
    // Abort the fetch request by calling abort() on the AbortController instance
    if (controller) {
      controller.abort();
      controller = null;
    }
  };

  aiPrompt.addEventListener("keyup", (event) => {
    if (event.key === "Enter") {
      generate();
    }
  });
  aiSubmit.addEventListener("click", generate);
  aiStop.addEventListener("click", stop);
}

// Forked from: https://jsfiddle.net/ourcodeworld/KJQ9K/1209/
function jsonHighlight(str) {
  try {
    json = JSON.stringify(JSON.parse(str), null, 2);
  } catch (e) {
    notification("The policy isn't a valid JSON object.");
    return;
  }

  json = json.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return json.replace(/("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+\-]?\d+)?)/g, function (match) {
    var cls = 'text-orange-700'; // number
    if (/^"/.test(match)) {
      if (/:$/.test(match)) {
        cls = 'text-rose-700 font-medium'; // key
      } else {
        cls = 'text-green-700'; // string
      }
    } else if (/true|false/.test(match)) {
      cls = 'text-blue-700'; // boolean
    } else if (/null/.test(match)) {
      cls = 'text-pink-700'; // null
    }
    return '<span class="' + cls + '">' + match + '</span>';
  });
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

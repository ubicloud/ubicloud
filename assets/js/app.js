$(function() {
  setupAutoRefresh();
  setupDatePicker();
  setupFormOptionUpdates();
  setupAceDeleteButtons();
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


$(document).click(function(){
  $(".dropdown").removeClass("active");
});

$(".dropdown").on("click", function (event) {
  event.stopPropagation();
  $(this).toggleClass("active");
});

$(".sidebar-group-btn").on("click", function (event) {
  $(this).parent().toggleClass("active");
});

var num_aces = 0;
$("#new-ace-btn").on("click", function (event) {
  event.preventDefault();
  num_aces++;
  var template = $('#ace-template').clone().removeClass('hidden').removeAttr('id');
  var pos = 0;
  template.find('select').each(function(i, element) {
    pos++;
    $(element).attr('id', 'ace-select-' + num_aces + '-' + pos)
  });
  template.insertBefore('#access-control-entries tbody tr:last')
    .find('input[name="aces[][ubid]"]').first().val("new");
  $('#access-control-entries tr:not(.hidden) select[name="aces[][subject]"]').attr('required', true);
  setupAceDeleteButtons();
});

function setupAceDeleteButtons() {
  $(".remove-ace-btn").off('click').on("click", function (event) {
    event.preventDefault();
    let row = $(this).closest("tr");
    row.find('input[name="aces[][deleted]"]').first().val("true");
    row.addClass("hidden");
  });
}

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
        dataType : "json",
        headers: {"Accept": "application/json"},
        success: function (result) {
            window.location.href = redirect;
        },
        error: function (xhr, ajaxOptions, thrownError) {
          if(xhr.status == 404){
            window.location.href = redirect;
            return;
          }

          let message = thrownError;
          try {
            response = JSON.parse(xhr.responseText);
            message = response.error?.message
          } catch {};
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
  $("div.auto-refresh").each(function() {
    const interval = $(this).data("interval");
    setTimeout(function() {
      location.reload();
    }, interval * 1000);
  });
}

function setupDatePicker() {
  if (!$.prototype.flatpickr) { return; }

  $(".datepicker").each(function() {
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
  $('#creation-form').on('change', 'input', function() {
    let name = $(this).attr('name');
    option_dirty[name] = $(this).val();

    if ($(this).attr('type') !== 'radio') {
      return;
    }
    redrawChildOptions(name);
  });
}

function redrawChildOptions(name){
  if(option_children[name]) {
    let value = $("input[name=" + name + "]:checked").val();
    let classes = $("input[name=" + name + "]:checked").parent().attr('class');
    classes = classes ? classes.split(" ") : [];
    classes = "." + classes.concat("form_" + name, "form_" + name + "_" + value).join('.');

    option_children[name].forEach(function(child_name){
      let child_type = document.getElementsByName(child_name)[0].nodeName.toLowerCase();
      if(child_type == "input"){
        child_type = "input_" + document.getElementsByName(child_name)[0].type.toLowerCase();
      }

      let elements2select = [];
      switch(child_type){
        case "input_radio":
          $("input[name=" + child_name + "]").parent().hide()
          $("input[name=" + child_name + "]").prop('disabled', true).prop('checked', false).prop('selected', false);
          $("input[name=" + child_name + "]").parent(classes).show()
          $("input[name=" + child_name + "]").parent(classes).children("input[name=" + child_name + "]").prop('disabled', false);

          if(option_dirty[child_name]){
            elements2select = $("input[name=" + child_name + "][value=" + option_dirty[child_name] + "]").parent(classes);
          }

          if(elements2select.length == 0){
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

          if(option_dirty[child_name]){
            elements2select = $("select[name=" + child_name + "]").children(classes + "[value=" + option_dirty[child_name] + "]");
          }

          if(elements2select.length == 0){
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

$(function() {
  setupPolicyEditor();
  setupLocationBasedPrices();
  setupLocationBasedOptions();
  setupAutoRefresh();
  setupPrint();
  setupDatePicker();
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

$(".radio-stacked-cards input[type=radio]").on("change", function (event) {
    let name = $(this).attr("name");
    $(`#${name}-radios label`).removeClass("border-orange-600 ring-2 ring-orange-600");
    $(`#${name}-radios label span.pointer-events-none`)
        .removeClass("border-transparent")
        .addClass("border-2");

    $(this)
        .parent()
        .addClass("border-orange-600 ring-2 ring-orange-600");
    $(this)
        .parent()
        .children("span.pointer-events-none")
        .removeClass("border-2")
        .addClass("border-transparent");
});

$(".delete-btn").on("click", function (event) {
    event.preventDefault();
    let url = $(this).data("url");
    let csrf = $(this).data("csrf");
    let confirmation = $(this).data("confirmation");
    let redirect = $(this).data("redirect");

    if (!confirm("Are you sure to delete?")) {
        return;
    }

    if (confirmation && prompt(`Please type "${confirmation}" to confirm deletion`, "") != confirmation) {
        alert("Could not confirm resource name");
        return;
    }

    $.ajax({
        url: url,
        type: "DELETE",
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
            err = JSON.parse(xhr.responseText);
            message = err.message
          } catch {};
          alert(`Error: ${message}`);
        }
    });
});

$(".copieble-content").on("click", ".copy-button", function (event) {
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
  $(".policy-editor").each(function() {
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

$("input[name=location]").on("change", function (event) {
  setupLocationBasedPrices();
  setupLocationBasedPostgresHaPrices();
  setupLocationBasedOptions();
});

$("input[name=size]").on("change", function (event) {
  setupLocationBasedPostgresHaPrices();
});

function setupLocationBasedPrices() {
  let selectedLocation = $("input[name=location]:checked")
  let prices = selectedLocation.length ? selectedLocation.data("details") : {};
  let count = {}
  $("input.location-based-price").each(function(i, obj) {
    let name = $(this).attr("name");
    let value = $(this).val();
    let resource_type = Array.isArray($(this).data("resource-type")) ? $(this).data("resource-type") : [$(this).data("resource-type")];
    let resource_family = Array.isArray($(this).data("resource-family")) ? $(this).data("resource-family") : [$(this).data("resource-family")];
    let amount = Array.isArray($(this).data("amount")) ? $(this).data("amount") : [$(this).data("amount")];
    let is_default = $(this).data("default");

    let monthly = 0;
    for(var i = 0; i < resource_type.length; i++) {
      if (monthlyPrice = prices?.[resource_type[i]]?.[resource_family[i]]?.["monthly"]) {
        monthly += monthlyPrice * amount[i];
      } else {
        $(`.${name}-${value}`).hide();
        if (!is_default) {
          $(this).prop('checked', false);
        }

        return;
      }
    }

    $(this).data("monthly-price", monthly.toFixed(2));
    $(`.${name}-${value}`).show();
    $(`.${name}-${value}-monthly-price`).text(`$${monthly.toFixed(2)}`);
    count[name] = (count[name] || 0) + 1;
  });
}

function setupLocationBasedPostgresHaPrices() {
  $("input.location-based-postgres-ha-price").each(function(i, obj) {
    let value = $(this).val();
    let monthlyPrice = $("input[name=size]:checked").data("monthly-price");
    let standbyCount = $(this).data("standby-count");
    $(`.ha-status-${value}`).show();
    $(`.ha-status-${value}-monthly-price`).text(`+$${(standbyCount * monthlyPrice).toFixed(2)}`);
  });
}

function setupLocationBasedOptions() {
  let selectedLocation = $("input[name=location]:checked").val();
  $(".location-based-option").hide().prop('disabled', true).prop('checked', false).prop('selected', false);
  if (selectedLocation) {
    $(`.location-based-option.${selectedLocation}`).show().prop('disabled', false);
  }
}

function setupAutoRefresh() {
  $("div.auto-refresh").each(function() {
    const interval = $(this).data("interval");
    setTimeout(function() {
      location.reload();
    }, interval * 1000);
  });
}

function setupPrint() {
  $("div.print-page").each(function() {
    window.print();
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
$(function() {
  setupPolicyEditor();
  setupLocationBasedPrices();
  setupLocationBasedOptions();
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
          let message = thrownError;
          try {
            err = JSON.parse(xhr.responseText);
            message = err.message
          } catch {};
          alert(`Error: ${message}`);
        }
    });
});

$(".copy-content").on("click", function (event) {
    let content = $(this).data("content");
    let message = $(this).data("message");
    navigator.clipboard.writeText(content);

    if (message) {
        notification(message);
    }
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
  setupLocationBasedOptions();
});

function setupLocationBasedPrices() {
  let selectedLocation = $("input[name=location]:checked")
  let prices = selectedLocation.length ? selectedLocation.data("details") : {};
  let count = {}
  $("input.location-based-price").each(function(i, obj) {
    let name = $(this).attr("name");
    let value = $(this).val();
    let resource_type = $(this).data("resource-type");
    let resource_family = $(this).data("resource-family");
    let amount = $(this).data("amount");
    let is_default = $(this).data("default");
    if (monthlyPrice = prices?.[resource_type]?.[resource_family]?.["monthly"]) {
      let monthly = monthlyPrice * amount;
      $(`.${name}-${value}`).show();
      $(`.${name}-${value}-monthly-price`).text(`$${monthly.toFixed(2)}`);
      count[name] = (count[name] || 0) + 1;
    } else {
      $(`.${name}-${value}`).hide();
      if (!is_default) {
        $(this).prop('checked', false);
      }
    }
    if (count[name]) {
      $("#" + name + "-description").hide();
    } else {
      $("#" + name + "-description").show();
    }
  });
}

function setupLocationBasedOptions() {
  let selectedLocation = $("input[name=location]:checked").val();
  $(".location-based-option").hide().prop('disabled', true).prop('checked', false).prop('selected', false);
  if (selectedLocation) {
    $(`.location-based-option.${selectedLocation}`).show().prop('disabled', false);
  }
}

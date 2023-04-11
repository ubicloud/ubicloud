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

$(".radio-stacked-cards input[type=radio]").on("change", function (event) {
    let name = $(this).attr("name");
    $(`#${name}-radios label`).removeClass("border-indigo-600 ring-2 ring-indigo-600");
    $(`#${name}-radios label span.pointer-events-none`)
        .removeClass("border-transparent")
        .addClass("border-2");

    $(this)
        .parent()
        .addClass("border-indigo-600 ring-2 ring-indigo-600");
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
        type: 'DELETE',
        data: { '_csrf': csrf },
        success: function (result) {
            window.location.href = redirect;
        },
        error: function (xhr, ajaxOptions, thrownError) {
            alert(`Error: ${thrownError}`);
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

// Show price change for demo
$("#location-radios input[type=radio]").on("change", function (event) {
    let location = $(this).val();
    $('#size-radios .size-price').each(function (i, obj) {
        let prices = $(this).data("prices");
        let price = prices[location] || prices["default"]
        $(this).text(`$${price.toFixed(2)}`)
    });
});

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

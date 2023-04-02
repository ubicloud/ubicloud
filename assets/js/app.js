$(".toggle-mobile-menu").on("click", function(event) {
    if ($("#mobile-menu").is(":hidden")) {
        $("#mobile-menu").show(0, function() {
            $("#mobile-menu .menu-outer").addClass("opacity-100").removeClass("opacity-0");
            $("#mobile-menu .menu-inner").addClass("translate-x-0").removeClass("-translate-x-full");
        });
    } else {
        $("#mobile-menu .menu-outer").addClass("opacity-0").removeClass("opacity-100");
        $("#mobile-menu .menu-inner").addClass("-translate-x-full").removeClass("translate-x-0");
        setTimeout(function(){
            $("#mobile-menu").hide();
        }, 300);
    }
});

$(".radio-small-cards input[type=radio]").on("change", function(event) {
    let name = $(this).attr("name");
    $(`#${name}-radios label`)
        .addClass("ring-1 ring-inset ring-gray-300 bg-white text-gray-900 hover:bg-gray-50")
        .removeClass("ring-2 ring-indigo-600 ring-offset-2 bg-indigo-600 text-white hover:bg-indigo-500");
    $(this).parent()
        .removeClass("ring-1 ring-inset ring-gray-300 bg-white text-gray-900 hover:bg-gray-50")
        .addClass("ring-2 ring-indigo-600 ring-offset-2 bg-indigo-600 text-white hover:bg-indigo-500");
});

$(".radio-stacked-cards input[type=radio]").on("change", function(event) {
    let name = $(this).attr("name");
    $(`#${name}-radios label`).removeClass("border-indigo-600 ring-2 ring-indigo-600");
    $(`#${name}-radios label span.pointer-events-none`).removeClass("border-transparent").addClass("border-2");

    $(this).parent().addClass("border-indigo-600 ring-2 ring-indigo-600");
    $(this).parent().children("span.pointer-events-none").removeClass("border-2").addClass("border-transparent");
});

$(".delete-btn").on("click", function(event) {
    event.preventDefault();
    let url = $(this).data("url");
    let csrf = $(this).data("csrf");

    if (!confirm("Are you sure to delete?")) {
        return;
    }

    $.ajax({
        url: url,
        type: 'DELETE',
        data: {'_csrf': csrf},
        success: function(result) {
            alert(result);
            location.reload();
        },
        error: function (xhr, ajaxOptions, thrownError) {
            alert(`Error: ${thrownError}`);
        }
    });
});

$(".copy-content").on("click", function(event) {
    let content = $(this).data("content");
    let message = $(this).data("message");
    navigator.clipboard.writeText(content);
    notification(message);
})

function notification(message) {
    let container = $("#notification-template").parent();
    let newNotification = $("#notification-template").clone();
    newNotification.find("p").text(message);
    newNotification.appendTo(container).show(0, function() {
        $(this).removeClass("translate-y-2 opacity-0 sm:translate-y-0 sm:translate-x-2").addClass("translate-y-0 opacity-100 sm:translate-x-0");
    });

    setTimeout(function(){
        newNotification.remove();
    }, 2000);
}
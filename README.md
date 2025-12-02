**Fast-Add Recovery Tool** (FART) is a plugin for Koha that allows library staff to recover items that have been deleted by searching Barcodes. This tool recovers the item record and bibliographic record (if one does not already exist) from the deleteditems, deletedbiblio, deletedbiblioitems, and deletedbiblio_metadata DB tables in Koha. Lastly it calls a reindexing of all items. To use; install the plugin, run tool, search for a list of barcodes to recover (limit 100).

<img width="1024" height="1024" alt="F-ART" src="https://github.com/user-attachments/assets/868c0bc2-0f33-49b9-a1f3-6e76abd5e985" />

Made by Samuel Sowanick for Corvallis-Benton County Public Library System. Based off the Undelete Records plugin by David Bourgault, InLibro.

Pair with the below JQuery in IntranetUserJS to have quicklinks to the Tool in Circulation and Cataloging.
```
$(document).ready(function() {
    var newItemRecoveryButton = '<li>' +
    '<a class="circ-button" href="https://staff-corvallis.bywatersolutions.com/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AItemRecovery&method=tool">' +
    '<i class="fa fa-undo"></i> Item Recovery' +
    '</a>' +
    '</li>';

  // 2. Select the 'ul.buttons-list' that immediately follows the 'h3:contains("Tools")'
  // This targets only the list in the Tools section.
  $('h3:contains("Tools")').next('.buttons-list').append(newItemRecoveryButton);
});

//Checkin
$(document).ready(function() {
  if ($(".problem.ret_badbarcode:contains('No item with barcode:')")) {
      $('.problem.ret_badbarcode').append('<div>' +
    '<a class="btn btn-default approve" href="https://staff-corvallis.bywatersolutions.com/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AItemRecovery&method=tool">' +
    '<i class="fa fa-undo"></i> Fast Add Recovery Tool' +
    '</a>' +
    '</div>');
  }
});

//Checkout
$(document).ready(function() {
  if ($(".circ_impossible:contains('he barcode was not found:')")) {
      $('#circ_impossible > ul > li > div').prepend('<div>' +
    '<a class="btn btn-default approve" href="https://staff-corvallis.bywatersolutions.com/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AItemRecovery&method=tool">' +
    '<i class="fa fa-undo"></i> Fast Add Recovery Tool' +
    '</a>' +
    '</div>');
  }
});
```

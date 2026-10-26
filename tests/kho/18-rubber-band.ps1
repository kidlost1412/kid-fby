# D11: rubber-band hit test (pure function over the KidWrapPanel geometry). Cells 200x300, 3 columns, viewport 650 wide -> left pad 25.
. (Join-Path $PSScriptRoot '_load.ps1')
function Hits {
    param($ax, $ay, $px, $py, $scroll = 0, $count = 30, $cols = 3, $vw = 650)
    return ((Get-RubberBandHits -AnchorX $ax -AnchorY $ay -PointX $px -PointY $py -ScrollOffset $scroll -ItemWidth 200 -ItemHeight 300 -Columns $cols -ViewportWidth $vw -Count $count) -join ',')
}
Test-Case 'inside one cell -> that cell only' { Assert-Equal (Hits 30 10 100 100) '0' }
Test-Case 'partial overlap of two cells in a row (cell 1 starts at x=225)' { Assert-Equal (Hits 30 10 260 100) '0,1' }
Test-Case 'two rows in one column' { Assert-Equal (Hits 30 10 100 350) '0,3' }
Test-Case 'a block across 2 columns x 2 rows' { Assert-Equal (Hits 100 100 300 400) '0,1,3,4' }
Test-Case 'reversed drag (pointer up-left of the anchor) selects the same cells' { Assert-Equal (Hits 300 400 100 100) '0,1,3,4' }
Test-Case 'scroll offset: anchor pressed at scroll 600 (content y 610), pointer at viewport y 100 with scroll 600 -> row 2 only' {
    Assert-Equal (Hits 30 610 100 100 600) '6'
}
Test-Case 'scroll offset: same anchor, the view auto-scrolled to 900 -> content y 1000 -> rows 2 and 3' {
    Assert-Equal (Hits 30 610 100 100 900) '6,9'
}
Test-Case 'scroll offset moves the selection up too: anchor at content y 1000, pointer viewport y 20 at scroll 0 -> rows 0..3' {
    Assert-Equal (Hits 30 1000 100 20 0) '0,3,6,9'
}
Test-Case 'left padding area selects nothing' { Assert-Equal (Hits 2 10 20 100) '' }
Test-Case 'a rectangle touching a cell edge exactly does not select it (x=225 is the left edge of column 1)' {
    Assert-Equal (Hits 30 10 225 100) '0'
    Assert-Equal (Hits 30 10 225.5 100) '0,1'
}
Test-Case 'indices beyond Count are never returned (5 items, 3 columns)' { Assert-Equal (Hits 30 10 600 900 0 5) '0,1,2,3,4' }
Test-Case 'zero-area rectangle (a plain click) and empty list select nothing' {
    Assert-Equal (Hits 100 100 100 100) ''
    Assert-Equal (Hits 100 100 100 200) ''
    Assert-Equal (Hits 30 10 600 900 0 0) ''
}
Test-Case 'a narrow viewport with one column: pad is zero when the viewport is narrower than the cell grid' {
    Assert-Equal ((Get-RubberBandHits -AnchorX 10 -AnchorY 10 -PointX 150 -PointY 700 -ScrollOffset 0 -ItemWidth 200 -ItemHeight 300 -Columns 1 -ViewportWidth 200 -Count 10) -join ',') '0,1,2'
}
Test-Case 'large list (2500 items, 4 columns): a band deep in the list touches only its own rows (x 10..400 reaches columns 0 and 1; x=400 is the edge of column 2)' {
    $r = Get-RubberBandHits -AnchorX 10 -AnchorY 150000 -PointX 400 -PointY 0 -ScrollOffset 150600 -ItemWidth 200 -ItemHeight 300 -Columns 4 -ViewportWidth 800 -Count 2500
    Assert-Equal ($r -join ',') '2000,2001,2004,2005'
}
Complete-Tests

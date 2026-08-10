#import "ScintillaCocoaBridge.h"

#import "Scintilla.h"
#import "ScintillaView.h"

static NSString *const MTEEditorErrorDomain = @"MacTextEditor.Scintilla";
static const int MTESearchIndicator = 8;
static const int MTELineNumberMargin = 0;
static const int MTELineNumberPaddingMargin = 1;
static const int MTESeparatorMargin = 2;
static const long MTEMinimumLineNumberMarginWidth = 32;

static long MTEColorValue(NSColor *color) {
    NSColor *deviceColor = [color colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    const long red = static_cast<long>(deviceColor.redComponent * 255);
    const long green = static_cast<long>(deviceColor.greenComponent * 255);
    const long blue = static_cast<long>(deviceColor.blueComponent * 255);
    return (blue << 16) + (green << 8) + red;
}

@implementation MTEEditorMatch

- (instancetype)initWithByteRange:(NSRange)byteRange
                       lineNumber:(NSInteger)lineNumber
                         lineText:(NSString *)lineText {
    self = [super init];
    if (self) {
        _byteRange = byteRange;
        _lineNumber = lineNumber;
        _lineText = [lineText copy];
    }
    return self;
}

@end

@implementation MTEEditorSearchBatch

- (instancetype)initWithMatches:(NSArray<MTEEditorMatch *> *)matches
                    nextPosition:(NSInteger)nextPosition
                        finished:(BOOL)finished {
    self = [super init];
    if (self) {
        _matches = [matches copy];
        _nextPosition = nextPosition;
        _finished = finished;
    }
    return self;
}

@end

@interface MTEFileDropContentView : SCIContentView
@end

@interface MTEFileDropScintillaView : ScintillaView
@property(nonatomic, copy) void (^fileDropHandler)(NSArray<NSURL *> *urls);
@end

static NSArray<NSURL *> *MTEFileURLs(id<NSDraggingInfo> sender) {
    NSArray *objects = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class]
                                                               options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSURL *url in objects) {
        NSNumber *isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        if (url.isFileURL && !isDirectory.boolValue) {
            [urls addObject:url];
        }
    }
    return urls;
}

@implementation MTEFileDropScintillaView

+ (Class)contentViewClass {
    return MTEFileDropContentView.class;
}

@end

@implementation MTEFileDropContentView

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return MTEFileURLs(sender).count > 0 ? NSDragOperationCopy : [super draggingEntered:sender];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    return MTEFileURLs(sender).count > 0 ? NSDragOperationCopy : [super draggingUpdated:sender];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSArray<NSURL *> *urls = MTEFileURLs(sender);
    if (urls.count == 0) {
        return [super performDragOperation:sender];
    }

    NSView *ancestor = self.superview;
    while (ancestor && ![ancestor isKindOfClass:MTEFileDropScintillaView.class]) {
        ancestor = ancestor.superview;
    }
    MTEFileDropScintillaView *scintilla = (MTEFileDropScintillaView *)ancestor;
    if (!scintilla.fileDropHandler) {
        return NO;
    }
    scintilla.fileDropHandler(urls);
    return YES;
}

@end

@interface MTEEditorView () <ScintillaNotificationProtocol>
@property(nonatomic, strong) ScintillaView *scintilla;
@property(nonatomic) NSInteger lineNumberDigits;
@property(nonatomic) BOOL incrementalLoadEditable;
@end

@implementation MTEEditorView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        MTEFileDropScintillaView *scintilla = [[MTEFileDropScintillaView alloc] initWithFrame:self.bounds];
        __weak MTEEditorView *weakSelf = self;
        scintilla.fileDropHandler = ^(NSArray<NSURL *> *urls) {
            MTEEditorView *strongSelf = weakSelf;
            if (strongSelf.fileDropHandler) {
                strongSelf.fileDropHandler(urls);
            }
        };
        _scintilla = scintilla;
        _scintilla.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _scintilla.delegate = self;
        [self addSubview:_scintilla];
        [self configureEditor];
    }
    return self;
}

- (void)configureEditor {
    [_scintilla setGeneralProperty:SCI_SETCODEPAGE value:SC_CP_UTF8];
    [_scintilla setGeneralProperty:SCI_SETMODEVENTMASK
                             value:SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT];
    [_scintilla setGeneralProperty:SCI_SETWRAPMODE value:SC_WRAP_NONE];
    [_scintilla setGeneralProperty:SCI_SETSCROLLWIDTHTRACKING value:1];
    [_scintilla setGeneralProperty:SCI_SETMARGINTYPEN parameter:MTELineNumberMargin value:SC_MARGIN_NUMBER];
    [_scintilla setGeneralProperty:SCI_SETMARGINTYPEN parameter:MTELineNumberPaddingMargin value:SC_MARGIN_COLOUR];
    [_scintilla setGeneralProperty:SCI_SETMARGINWIDTHN parameter:MTELineNumberPaddingMargin value:8];
    [_scintilla setGeneralProperty:SCI_SETMARGINSENSITIVEN parameter:MTELineNumberPaddingMargin value:0];
    [_scintilla setGeneralProperty:SCI_SETMARGINTYPEN parameter:MTESeparatorMargin value:SC_MARGIN_COLOUR];
    [_scintilla setGeneralProperty:SCI_SETMARGINWIDTHN parameter:MTESeparatorMargin value:1];
    [_scintilla setGeneralProperty:SCI_SETMARGINSENSITIVEN parameter:MTESeparatorMargin value:0];
    [_scintilla setGeneralProperty:SCI_SETMARGINCURSORN parameter:MTESeparatorMargin value:SC_CURSORARROW];
    [_scintilla setGeneralProperty:SCI_SETMARGINLEFT value:6];
    [_scintilla setFontName:@"Menlo" size:13 bold:NO italic:NO];

    [_scintilla setColorProperty:SCI_STYLESETFORE parameter:STYLE_DEFAULT value:NSColor.textColor];
    [_scintilla setColorProperty:SCI_STYLESETBACK parameter:STYLE_DEFAULT value:NSColor.textBackgroundColor];
    [_scintilla setGeneralProperty:SCI_STYLECLEARALL value:0];
    [_scintilla setColorProperty:SCI_STYLESETFORE parameter:STYLE_LINENUMBER value:NSColor.secondaryLabelColor];
    [_scintilla setColorProperty:SCI_STYLESETBACK parameter:STYLE_LINENUMBER value:NSColor.windowBackgroundColor];
    [_scintilla setColorProperty:SCI_SETMARGINBACKN parameter:MTELineNumberPaddingMargin value:NSColor.windowBackgroundColor];
    [_scintilla setColorProperty:SCI_SETMARGINBACKN parameter:MTESeparatorMargin value:NSColor.separatorColor];
    [_scintilla setGeneralProperty:SCI_SETCARETFORE value:MTEColorValue(NSColor.textColor)];
    [_scintilla setColorProperty:SCI_SETSELBACK parameter:1 value:NSColor.selectedTextBackgroundColor];

    [_scintilla setGeneralProperty:SCI_INDICSETSTYLE parameter:MTESearchIndicator value:INDIC_ROUNDBOX];
    [_scintilla setColorProperty:SCI_INDICSETFORE parameter:MTESearchIndicator value:NSColor.systemYellowColor];
    [_scintilla setGeneralProperty:SCI_INDICSETALPHA parameter:MTESearchIndicator value:90];
    [_scintilla setGeneralProperty:SCI_INDICSETUNDER parameter:MTESearchIndicator value:1];
    [self updateLineNumberMarginWidth];
}

- (void)updateLineNumberMarginWidth {
    const long firstVisibleLine = [_scintilla getGeneralProperty:SCI_GETFIRSTVISIBLELINE];
    const long linesOnScreen = MAX(1, [_scintilla getGeneralProperty:SCI_LINESONSCREEN]);
    const long lastVisibleLine = [_scintilla getGeneralProperty:SCI_DOCLINEFROMVISIBLE
                                                       parameter:firstVisibleLine + linesOnScreen - 1];
    long lineNumber = MAX(1, lastVisibleLine + 1);
    NSInteger digits = 1;
    while (lineNumber >= 10) {
        lineNumber /= 10;
        digits += 1;
    }
    if (_lineNumberDigits == digits)
        return;

    _lineNumberDigits = digits;
    const NSInteger visibleDigits = MAX(3, digits);
    NSMutableString *sample = [NSMutableString stringWithString:@"_"];
    for (NSInteger index = 0; index < visibleDigits; index++)
        [sample appendString:@"9"];
    const long textWidth = [_scintilla message:SCI_TEXTWIDTH
                                        wParam:STYLE_LINENUMBER
                                        lParam:reinterpret_cast<sptr_t>(sample.UTF8String)];
    [_scintilla setGeneralProperty:SCI_SETMARGINWIDTHN
                         parameter:MTELineNumberMargin
                             value:MAX(MTEMinimumLineNumberMarginWidth, textWidth + 4)];
}

- (void)loadString:(NSString *)string
          editable:(BOOL)editable
     largeDocument:(BOOL)largeDocument {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    _scintilla.content.accessibilityElement = !largeDocument;
    _scintilla.content.accessibilityEnabled = !largeDocument;
    if (largeDocument) {
        const int options = SC_DOCUMENTOPTION_STYLES_NONE | SC_DOCUMENTOPTION_TEXT_LARGE;
        const sptr_t document = [_scintilla message:SCI_CREATEDOCUMENT
                                             wParam:data.length
                                             lParam:options];
        if (document != 0) {
            [_scintilla message:SCI_SETDOCPOINTER wParam:0 lParam:document];
            [_scintilla message:SCI_RELEASEDOCUMENT wParam:0 lParam:document];
            [_scintilla setGeneralProperty:SCI_SETCODEPAGE value:SC_CP_UTF8];
        }
    }
    [_scintilla setEditable:YES];
    [_scintilla setGeneralProperty:SCI_SETUNDOCOLLECTION value:0];
    [_scintilla setGeneralProperty:SCI_CLEARALL value:0];
    if (data.length > 0) {
        [_scintilla message:SCI_APPENDTEXT
                     wParam:data.length
                     lParam:reinterpret_cast<sptr_t>(data.bytes)];
    }
    [_scintilla setGeneralProperty:SCI_SETUNDOCOLLECTION value:1];
    [_scintilla setGeneralProperty:SCI_EMPTYUNDOBUFFER value:0];
    [_scintilla setGeneralProperty:SCI_SETSAVEPOINT value:0];
    [_scintilla setGeneralProperty:SCI_GOTOPOS value:0];
    [_scintilla setEditable:editable];
    [self updateLineNumberMarginWidth];
}

- (void)beginIncrementalLoadWithUTF8Data:(NSData *)data
                          expectedLength:(NSInteger)expectedLength
                                editable:(BOOL)editable
                           largeDocument:(BOOL)largeDocument {
    _scintilla.content.accessibilityElement = !largeDocument;
    _scintilla.content.accessibilityEnabled = !largeDocument;
    if (largeDocument) {
        const int options = SC_DOCUMENTOPTION_STYLES_NONE | SC_DOCUMENTOPTION_TEXT_LARGE;
        const sptr_t document = [_scintilla message:SCI_CREATEDOCUMENT
                                             wParam:MAX(0, expectedLength)
                                             lParam:options];
        if (document != 0) {
            [_scintilla message:SCI_SETDOCPOINTER wParam:0 lParam:document];
            [_scintilla message:SCI_RELEASEDOCUMENT wParam:0 lParam:document];
            [_scintilla setGeneralProperty:SCI_SETCODEPAGE value:SC_CP_UTF8];
        }
    }
    _incrementalLoadEditable = editable;
    [_scintilla setEditable:YES];
    [_scintilla setGeneralProperty:SCI_SETUNDOCOLLECTION value:0];
    [_scintilla setGeneralProperty:SCI_CLEARALL value:0];
    if (data.length > 0) {
        [_scintilla message:SCI_ADDTEXT
                     wParam:data.length
                     lParam:reinterpret_cast<sptr_t>(data.bytes)];
    }
    [_scintilla setGeneralProperty:SCI_GOTOPOS value:0];
    [_scintilla setEditable:NO];
    [self updateLineNumberMarginWidth];
}

- (void)beginIncrementalReloadEditable:(BOOL)editable {
    _incrementalLoadEditable = editable;
    [_scintilla setEditable:YES];
    [_scintilla setGeneralProperty:SCI_SETUNDOCOLLECTION value:0];
    [_scintilla setGeneralProperty:SCI_GOTOPOS value:0];
    [_scintilla setEditable:NO];
}

- (void)beginIncrementalReplacementEditable:(BOOL)editable {
    _incrementalLoadEditable = editable;
    [_scintilla setEditable:YES];
    [_scintilla setGeneralProperty:SCI_BEGINUNDOACTION value:0];
    [_scintilla setGeneralProperty:SCI_GOTOPOS value:0];
    [_scintilla setEditable:NO];
}

- (NSInteger)deleteTrailingBytesWithMaximumLength:(NSInteger)maximumLength {
    const NSInteger length = [_scintilla getGeneralProperty:SCI_GETLENGTH];
    const NSInteger deletionLength = MIN(length, MAX(0, maximumLength));
    if (deletionLength == 0)
        return length;

    [_scintilla setEditable:YES];
    [_scintilla message:SCI_DELETERANGE
                 wParam:length - deletionLength
                 lParam:deletionLength];
    [_scintilla setEditable:NO];
    return length - deletionLength;
}

- (void)appendUTF8Data:(NSData *)data {
    if (data.length == 0)
        return;
    [_scintilla setEditable:YES];
    [_scintilla message:SCI_APPENDTEXT
                 wParam:data.length
                 lParam:reinterpret_cast<sptr_t>(data.bytes)];
    [_scintilla setEditable:NO];
}

- (void)finishIncrementalLoad {
    [_scintilla setEditable:YES];
    [_scintilla setGeneralProperty:SCI_SETUNDOCOLLECTION value:1];
    [_scintilla setGeneralProperty:SCI_EMPTYUNDOBUFFER value:0];
    [_scintilla setGeneralProperty:SCI_SETSAVEPOINT value:0];
    [_scintilla setEditable:_incrementalLoadEditable];
    [self updateLineNumberMarginWidth];
}

- (void)finishIncrementalReplacement {
    [_scintilla setEditable:YES];
    [_scintilla setGeneralProperty:SCI_ENDUNDOACTION value:0];
    [_scintilla setEditable:_incrementalLoadEditable];
    [self updateLineNumberMarginWidth];
}

- (NSData *)UTF8Data {
    const NSInteger length = [_scintilla getGeneralProperty:SCI_GETLENGTH];
    if (length == 0)
        return [NSData data];
    NSMutableData *data = [NSMutableData dataWithLength:length + 1];
    [_scintilla message:SCI_GETTEXT
                 wParam:length + 1
                 lParam:reinterpret_cast<sptr_t>(data.mutableBytes)];
    data.length = length;
    return data;
}

- (BOOL)isEditable {
    return _scintilla.isEditable;
}

- (void)setEditable:(BOOL)editable {
    _scintilla.editable = editable;
}

- (BOOL)isModified {
    return [_scintilla getGeneralProperty:SCI_GETMODIFY] != 0;
}

- (NSRange)selectedByteRange {
    return _scintilla.selectedRangePositions;
}

- (NSString *)selectedString {
    return _scintilla.selectedString;
}

- (NSInteger)currentLine {
    const long position = [_scintilla getGeneralProperty:SCI_GETCURRENTPOS];
    return [_scintilla getGeneralProperty:SCI_LINEFROMPOSITION parameter:position] + 1;
}

- (NSInteger)currentColumn {
    const long position = [_scintilla getGeneralProperty:SCI_GETCURRENTPOS];
    return [_scintilla getGeneralProperty:SCI_GETCOLUMN parameter:position] + 1;
}

- (NSInteger)documentLength {
    return [_scintilla getGeneralProperty:SCI_GETLENGTH];
}

- (NSString *)stringValue {
    return _scintilla.string;
}

- (void)replaceSelectedTextWithString:(NSString *)replacement {
    NSData *data = [replacement dataUsingEncoding:NSUTF8StringEncoding];
    [_scintilla setGeneralProperty:SCI_TARGETFROMSELECTION value:0];
    [_scintilla message:SCI_REPLACETARGET
                 wParam:data.length
                 lParam:reinterpret_cast<sptr_t>(data.bytes)];
}

- (MTEFindOptions)scintillaFindOptions:(MTEFindOptions)options {
    MTEFindOptions flags = 0;
    if ((options & MTEFindOptionMatchCase) != 0)
        flags |= SCFIND_MATCHCASE;
    if ((options & MTEFindOptionWholeWord) != 0)
        flags |= SCFIND_WHOLEWORD;
    if ((options & MTEFindOptionRegularExpression) != 0)
        flags |= SCFIND_REGEXP | SCFIND_CXX11REGEX;
    return flags;
}

- (NSString *)lineTextAtLine:(long)line aroundPosition:(long)position {
    const long lineStart = [_scintilla getGeneralProperty:SCI_POSITIONFROMLINE parameter:line];
    const long lineEnd = [_scintilla getGeneralProperty:SCI_GETLINEENDPOSITION parameter:line];
    if (lineEnd <= lineStart)
        return @"";

    const long relativeStart = [_scintilla getGeneralProperty:SCI_POSITIONRELATIVE
                                                    parameter:position
                                                        extra:-80];
    const long relativeEnd = [_scintilla getGeneralProperty:SCI_POSITIONRELATIVE
                                                  parameter:position
                                                      extra:240];
    const long previewStart = MAX(lineStart, relativeStart);
    const long previewEnd = MIN(lineEnd, relativeEnd > position ? relativeEnd : lineEnd);
    const long length = MAX(0, previewEnd - previewStart);
    NSMutableData *data = [NSMutableData dataWithLength:length + 1];
    Sci_TextRangeFull range = {{previewStart, previewEnd}, static_cast<char *>(data.mutableBytes)};
    [_scintilla message:SCI_GETTEXTRANGEFULL
                 wParam:0
                 lParam:reinterpret_cast<sptr_t>(&range)];
    NSString *text = [[NSString alloc] initWithBytes:data.bytes
                                              length:length
                                            encoding:NSUTF8StringEncoding];
    NSString *prefix = previewStart > lineStart ? @"…" : @"";
    NSString *suffix = previewEnd < lineEnd ? @"…" : @"";
    return [NSString stringWithFormat:@"%@%@%@", prefix, text ?: @"", suffix];
}

- (MTEEditorSearchBatch *)searchOccurrencesOfString:(NSString *)query
                                            options:(MTEFindOptions)options
                                       fromPosition:(NSInteger)fromPosition
                                          direction:(NSInteger)direction
                                          byteLimit:(NSInteger)byteLimit
                                       maximumCount:(NSInteger)maximumCount
                                              error:(NSError **)error {
    if (query.length == 0)
        return [[MTEEditorSearchBatch alloc] initWithMatches:@[] nextPosition:0 finished:YES];

    NSData *needle = [query dataUsingEncoding:NSUTF8StringEncoding];
    const long documentLength = [_scintilla getGeneralProperty:SCI_GETLENGTH];
    const long start = MIN(documentLength, MAX(0, fromPosition));
    const long limit = MAX(1, byteLimit);
    const long countLimit = MAX(1, maximumCount);
    const BOOL forward = direction >= 0;
    long boundary = forward ? MIN(documentLength, start + limit) : MAX(0, start - limit);
    const BOOL regularExpression = (options & MTEFindOptionRegularExpression) != 0;
    if (regularExpression && boundary > 0 && boundary < documentLength) {
        const long line = [_scintilla getGeneralProperty:SCI_LINEFROMPOSITION parameter:boundary];
        boundary = [_scintilla getGeneralProperty:SCI_POSITIONFROMLINE
                                        parameter:forward ? line + 1 : line];
    }
    const long overlap = regularExpression ? 0 : MAX(0, (long)needle.length - 1);
    const long targetBoundary = forward
        ? MIN(documentLength, boundary + overlap)
        : MAX(0, boundary - overlap);

    [_scintilla setGeneralProperty:SCI_SETSTATUS value:SC_STATUS_OK];
    [_scintilla setGeneralProperty:SCI_SETSEARCHFLAGS value:[self scintillaFindOptions:options]];
    [_scintilla setGeneralProperty:SCI_SETINDICATORCURRENT value:MTESearchIndicator];

    NSMutableArray<MTEEditorMatch *> *matches = [NSMutableArray array];
    long cursor = start;
    BOOL exhaustedRange = YES;
    while ((forward && cursor <= targetBoundary) || (!forward && cursor >= targetBoundary)) {
        [_scintilla setGeneralProperty:SCI_SETTARGETRANGE parameter:cursor value:targetBoundary];
        const long found = [_scintilla message:SCI_SEARCHINTARGET
                                        wParam:needle.length
                                        lParam:reinterpret_cast<sptr_t>(needle.bytes)];
        if (found < 0)
            break;
        const long matchStart = [_scintilla getGeneralProperty:SCI_GETTARGETSTART];
        const long matchEnd = [_scintilla getGeneralProperty:SCI_GETTARGETEND];
        if ((forward && boundary < documentLength && matchStart >= boundary) ||
            (!forward && boundary > 0 && matchEnd <= boundary))
            break;

        const long matchLength = MAX(0, matchEnd - matchStart);
        const long line = [_scintilla getGeneralProperty:SCI_LINEFROMPOSITION parameter:matchStart];
        [matches addObject:[[MTEEditorMatch alloc]
            initWithByteRange:NSMakeRange(matchStart, matchLength)
                   lineNumber:line + 1
                     lineText:[self lineTextAtLine:line aroundPosition:matchStart]]];
        [_scintilla setGeneralProperty:SCI_INDICATORFILLRANGE parameter:matchStart value:matchLength];

        if (forward) {
            if (matchEnd > matchStart) {
                cursor = matchEnd;
            } else {
                const long next = [_scintilla getGeneralProperty:SCI_POSITIONAFTER parameter:matchStart];
                cursor = next > matchStart ? next : matchStart + 1;
            }
        } else {
            const long previous = [_scintilla getGeneralProperty:SCI_POSITIONBEFORE parameter:matchStart];
            cursor = previous < matchStart ? previous : matchStart - 1;
        }
        if (matches.count >= countLimit) {
            exhaustedRange = NO;
            break;
        }
    }

    const long status = [_scintilla getGeneralProperty:SCI_GETSTATUS];
    if (status != SC_STATUS_OK) {
        if (error) {
            *error = [NSError errorWithDomain:MTEEditorErrorDomain
                                         code:status
                                     userInfo:@{NSLocalizedDescriptionKey: @"Scintilla 查找失败。"}];
        }
        return [[MTEEditorSearchBatch alloc] initWithMatches:@[] nextPosition:start finished:YES];
    }

    const long nextPosition = exhaustedRange ? boundary : cursor;
    const BOOL finished = forward ? nextPosition >= documentLength : nextPosition <= 0;
    return [[MTEEditorSearchBatch alloc] initWithMatches:matches
                                           nextPosition:nextPosition
                                               finished:finished];
}

- (NSString *)regularExpressionReplacement:(NSString *)replacement {
    NSMutableString *converted = [replacement mutableCopy];
    NSRegularExpression *capture = [NSRegularExpression regularExpressionWithPattern:@"\\$([0-9])"
                                                                              options:0
                                                                                error:nil];
    [capture replaceMatchesInString:converted
                            options:0
                              range:NSMakeRange(0, converted.length)
                       withTemplate:@"\\\\$1"];
    return converted;
}

- (NSInteger)replaceAllOccurrencesOfString:(NSString *)query
                                withString:(NSString *)replacement
                                   options:(MTEFindOptions)options
                                     error:(NSError **)error {
    if (query.length == 0)
        return 0;

    NSData *needle = [query dataUsingEncoding:NSUTF8StringEncoding];
    NSString *replacementText = (options & MTEFindOptionRegularExpression) != 0
        ? [self regularExpressionReplacement:replacement]
        : replacement;
    NSData *replacementData = [replacementText dataUsingEncoding:NSUTF8StringEncoding];
    [_scintilla setGeneralProperty:SCI_SETSTATUS value:SC_STATUS_OK];
    [_scintilla setGeneralProperty:SCI_SETSEARCHFLAGS value:[self scintillaFindOptions:options]];
    [_scintilla setGeneralProperty:SCI_BEGINUNDOACTION value:0];

    NSInteger count = 0;
    long start = 0;
    long end = [_scintilla getGeneralProperty:SCI_GETLENGTH];
    while (start <= end) {
        [_scintilla setGeneralProperty:SCI_SETTARGETRANGE parameter:start value:end];
        const long found = [_scintilla message:SCI_SEARCHINTARGET
                                        wParam:needle.length
                                        lParam:reinterpret_cast<sptr_t>(needle.bytes)];
        if (found < 0)
            break;
        const long oldEnd = [_scintilla getGeneralProperty:SCI_GETTARGETEND];
        const unsigned int replaceMessage = (options & MTEFindOptionRegularExpression) != 0
            ? SCI_REPLACETARGETRE
            : SCI_REPLACETARGET;
        const long replacementLength = [_scintilla message:replaceMessage
                                                      wParam:replacementData.length
                                                      lParam:reinterpret_cast<sptr_t>(replacementData.bytes)];
        count += 1;
        end += replacementLength - (oldEnd - found);
        if (oldEnd > found) {
            start = found + replacementLength;
        } else {
            const long next = [_scintilla getGeneralProperty:SCI_POSITIONAFTER
                                                   parameter:found + replacementLength];
            start = next > found ? next : found + replacementLength + 1;
        }
    }
    [_scintilla setGeneralProperty:SCI_ENDUNDOACTION value:0];
    [self clearSearchHighlights];

    const long status = [_scintilla getGeneralProperty:SCI_GETSTATUS];
    if (status != SC_STATUS_OK) {
        if (error) {
            *error = [NSError errorWithDomain:MTEEditorErrorDomain
                                         code:status
                                     userInfo:@{NSLocalizedDescriptionKey: @"Scintilla 替换失败。"}];
        }
        return 0;
    }
    return count;
}

- (void)selectAndRevealByteRange:(NSRange)range {
    [_scintilla setGeneralProperty:SCI_SETSEL
                         parameter:NSMaxRange(range)
                             value:range.location];
    [_scintilla setGeneralProperty:SCI_SCROLLCARET value:0];
}

- (void)clearSearchHighlights {
    const long length = [_scintilla getGeneralProperty:SCI_GETLENGTH];
    [_scintilla setGeneralProperty:SCI_SETINDICATORCURRENT value:MTESearchIndicator];
    [_scintilla setGeneralProperty:SCI_INDICATORCLEARRANGE parameter:0 value:length];
}

- (void)setSavePoint {
    [_scintilla setGeneralProperty:SCI_SETSAVEPOINT value:0];
}

- (void)focusEditor {
    [self.window makeFirstResponder:_scintilla.content];
}

- (void)notification:(SCNotification *)notification {
    switch (notification->nmhdr.code) {
        case SCN_MODIFIED:
            if (notification->linesAdded != 0)
                [self updateLineNumberMarginWidth];
            [self.delegate editorViewContentDidChange:self];
            break;
        case SCN_SAVEPOINTLEFT:
        case SCN_SAVEPOINTREACHED:
            [self.delegate editorViewContentDidChange:self];
            break;
        case SCN_UPDATEUI:
            if ((notification->updated & SC_UPDATE_V_SCROLL) != 0)
                [self updateLineNumberMarginWidth];
            [self.delegate editorViewSelectionDidChange:self];
            break;
        default:
            break;
    }
}

@end

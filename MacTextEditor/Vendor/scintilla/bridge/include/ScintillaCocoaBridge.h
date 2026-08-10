#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSUInteger, MTEFindOptions) {
    MTEFindOptionMatchCase = 1 << 0,
    MTEFindOptionWholeWord = 1 << 1,
    MTEFindOptionRegularExpression = 1 << 2,
};

@interface MTEEditorMatch : NSObject

@property(nonatomic, readonly) NSRange byteRange;
@property(nonatomic, readonly) NSInteger lineNumber;
@property(nonatomic, copy, readonly) NSString *lineText;

- (instancetype)initWithByteRange:(NSRange)byteRange
                       lineNumber:(NSInteger)lineNumber
                         lineText:(NSString *)lineText;

@end

@interface MTEEditorSearchBatch : NSObject

@property(nonatomic, copy, readonly) NSArray<MTEEditorMatch *> *matches;
@property(nonatomic, readonly) NSInteger nextPosition;
@property(nonatomic, readonly, getter=isFinished) BOOL finished;

- (instancetype)initWithMatches:(NSArray<MTEEditorMatch *> *)matches
                    nextPosition:(NSInteger)nextPosition
                        finished:(BOOL)finished;

@end

@protocol MTEEditorViewDelegate;

@interface MTEEditorView : NSView

@property(nonatomic, weak, nullable) id<MTEEditorViewDelegate> delegate;
@property(nonatomic, copy, nullable) void (^fileDropHandler)(NSArray<NSURL *> *urls);
@property(nonatomic, getter=isEditable) BOOL editable;
@property(nonatomic, readonly, getter=isModified) BOOL modified;
@property(nonatomic, readonly) NSRange selectedByteRange;
@property(nonatomic, copy, readonly) NSString *selectedString;
@property(nonatomic, readonly) NSInteger currentLine;
@property(nonatomic, readonly) NSInteger currentColumn;
@property(nonatomic, readonly) NSInteger documentLength;
@property(nonatomic, copy, readonly) NSString *stringValue;
@property(nonatomic, copy, readonly) NSData *UTF8Data;

- (void)loadString:(NSString *)string
          editable:(BOOL)editable
     largeDocument:(BOOL)largeDocument;
- (void)beginIncrementalLoadWithUTF8Data:(NSData *)data
                          expectedLength:(NSInteger)expectedLength
                                editable:(BOOL)editable
                           largeDocument:(BOOL)largeDocument;
- (void)beginIncrementalReloadEditable:(BOOL)editable
    NS_SWIFT_NAME(beginIncrementalReload(editable:));
- (void)beginIncrementalReplacementEditable:(BOOL)editable
    NS_SWIFT_NAME(beginIncrementalReplacement(editable:));
- (NSInteger)deleteTrailingBytesWithMaximumLength:(NSInteger)maximumLength
    NS_SWIFT_NAME(deleteTrailingBytes(maximumLength:));
- (void)appendUTF8Data:(NSData *)data;
- (void)finishIncrementalLoad;
- (void)finishIncrementalReplacement;
- (void)replaceSelectedTextWithString:(NSString *)replacement;
- (NSInteger)replaceAllOccurrencesOfString:(NSString *)query
                                withString:(NSString *)replacement
                                   options:(MTEFindOptions)options
                                     error:(NSError **)error;
- (MTEEditorSearchBatch *)searchOccurrencesOfString:(NSString *)query
                                            options:(MTEFindOptions)options
                                       fromPosition:(NSInteger)fromPosition
                                          direction:(NSInteger)direction
                                          byteLimit:(NSInteger)byteLimit
                                       maximumCount:(NSInteger)maximumCount
                                              error:(NSError **)error;
- (void)selectAndRevealByteRange:(NSRange)range;
- (void)clearSearchHighlights;
- (void)setSavePoint;
- (void)focusEditor;

@end

@protocol MTEEditorViewDelegate <NSObject>

- (void)editorViewContentDidChange:(MTEEditorView *)editorView;
- (void)editorViewSelectionDidChange:(MTEEditorView *)editorView;

@end


NS_ASSUME_NONNULL_END

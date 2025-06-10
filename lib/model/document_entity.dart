import 'package:objectbox/objectbox.dart';

/// Represents a document with its text content and a vector embedding.
@Entity()
class Document {
  /// The unique ID of the document, managed by ObjectBox.
  @Id()
  int id = 0;

  /// NEW: The timestamp of when the data was captured.
  /// This is indexed as a Date type for efficient time-based queries.
  @Property(type: PropertyType.date)
  DateTime timestamp;

  /// The original text content of the document.
  String textContent;

  /// The vector embedding of the document's content.
  /// This property is indexed for fast vector similarity searches.
  @Property(type: PropertyType.floatVector)
  @HnswIndex(
    // IMPORTANT: You must set the dimensions to match your embedding model.
    // Common values are 384, 512, 768, or 1536.
    dimensions: 384,
    // COSINE distance is often best for semantic similarity.
    // Other options include EUCLIDEAN and DOT_PRODUCT.
    distanceType: VectorDistanceType.cosine,
  )
  List<double>? embedding;

  Document({
    this.id = 0,
    required this.timestamp, // Make timestamp required
    required this.textContent,
    this.embedding,
  });
}
